import CoreGraphics
import ProxyPlayerKit
import SwiftUI

struct FeedDemoRootView: View {
    let model: FeedDemoModel

    var body: some View {
        let arguments = ProcessInfo.processInfo.arguments
        Group {
            if arguments.contains("--qualification-mode") {
                FeedDemoQualificationView(model: model)
            } else {
                FeedDemoShell(
                    model: model,
                    showsQualificationControls: arguments.contains(
                        "--vertical-qualification-mode"
                    )
                )
            }
        }
            .task {
                await model.start()
            }
            .onDisappear {
                Task { await model.stop() }
            }
    }
}

private struct FeedDemoQualificationView: View {
    let model: FeedDemoModel

    var body: some View {
        VStack(spacing: 12) {
            Text("HLS FEED QUALIFICATION", bundle: #bundle)
                .font(.caption.bold())
                .foregroundStyle(.mint)

            if let engine = model.engine, let focused = model.focusedItemID {
                HLSFeedVideo(engine: engine, itemID: focused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                qualificationValue(
                    title: "Focus",
                    value: model.focusedItemID?.rawValue ?? "none",
                    identifier: "qualification-focus"
                )
                qualificationValue(
                    title: "Navigations",
                    value: String(model.qualificationNavigationCount),
                    identifier: "qualification-navigation-count"
                )
                qualificationValue(
                    title: "Playback",
                    value: playbackStatus,
                    identifier: "qualification-playback-state"
                )
            }

            HStack {
                Button {
                    Task { await model.markQualificationWarmup() }
                } label: {
                    Text("Mark warmup", bundle: #bundle)
                }
                .accessibilityIdentifier("qualification-mark-warmup")
                .accessibilityValue(model.qualificationWarmupIsMarked ? "ready" : "pending")

                Button {
                    model.advanceQualification()
                } label: {
                    Text("Next", bundle: #bundle)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("qualification-next")

                Button {
                    Task { await model.finishQualification() }
                } label: {
                    Text("Finish", bundle: #bundle)
                }
                .accessibilityIdentifier("qualification-finish")
            }

            Text(qualificationResult)
                .font(.headline.monospaced())
                .foregroundStyle(model.qualificationReport?.passed == false ? .red : .green)
                .accessibilityIdentifier("qualification-result")
                .accessibilityValue(model.qualificationReport?.passed == true ? "PASS" : qualificationResult)

            Text(verbatim: model.qualificationReport?.json ?? "pending")
                .font(.system(size: 1))
                .lineLimit(1)
                .frame(height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("qualification-report")
                .accessibilityLabel("Qualification JSON")
                .accessibilityValue(model.qualificationReport?.json ?? "pending")

            Text(readinessStatus)
                .font(.caption2)
                .foregroundStyle(.white)
                .accessibilityIdentifier("qualification-ready")
                .accessibilityValue(readinessStatus)
        }
        .padding()
        .background(Color.black, ignoresSafeAreaEdges: .all)
        .tint(.mint)
    }

    private func qualificationValue(
        title: LocalizedStringKey,
        value: String,
        identifier: String
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Text(verbatim: value)
                .font(.caption.monospaced())
                .foregroundStyle(.white)
                .lineLimit(1)
                .accessibilityIdentifier(identifier)
                .accessibilityValue(value)
        }
        .frame(maxWidth: .infinity)
    }

    private var playbackStatus: String {
        guard let focused = model.focusedItemID,
              let playback = model.engineSnapshot.playback(for: focused)
        else {
            return "Starting"
        }
        if playback.hasStartedPlayback { return "Playing" }
        return switch playback.phase {
        case .loading: "Loading"
        case .warm: "Warm"
        case .focused: "Starting"
        case .failed: "Failed"
        }
    }

    private var readinessStatus: String {
        switch model.status {
        case .idle: "Idle"
        case .starting: "Starting"
        case .running: "Ready"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private var qualificationResult: String {
        guard let report = model.qualificationReport else { return "PENDING" }
        return report.passed ? "PASS" : "FAIL: \(report.failures.joined(separator: "; "))"
    }
}

private struct FeedDemoShell: View {
    @State private var isInspectorPresented = false
    @State private var isCreditsPresented = false

    let model: FeedDemoModel
    let showsQualificationControls: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FeedDemoPrimaryContent(model: model)
        }
        .overlay(alignment: .top) {
            FeedDemoPrimaryChrome(model: model)
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .trailing, spacing: 8) {
                if showsQualificationControls {
                    FeedDemoVerticalQualificationControls(model: model)
                        .padding(.horizontal, 12)
                } else {
                    FeedDemoAnalyticsLauncher(
                        inspector: model.analyticsInspector,
                        onOpen: { isInspectorPresented = true }
                    )
                    .padding(.horizontal, 16)
                }
                FeedDemoPrimaryHUD(
                    entries: model.entries,
                    focusedItemID: model.focusedItemID,
                    focusedPlayback: model.focusedItemID.flatMap {
                        model.engineSnapshot.playback(for: $0)
                    },
                    metrics: model.metrics,
                    showsPageTitle: model.selectedMode.layout == .paged,
                    showsCredits: !model.mediaSources.isEmpty,
                    onOpenCredits: { isCreditsPresented = true }
                )
            }
        }
        .tint(.mint)
        .sheet(isPresented: $isCreditsPresented) {
            FeedDemoMediaCreditsView(sources: model.mediaSources) {
                isCreditsPresented = false
            }
        }
        .sheet(isPresented: $isInspectorPresented) {
            FeedDemoAnalyticsInspectorView(
                inspector: model.analyticsInspector,
                onClose: { isInspectorPresented = false }
            )
        }
    }
}

private struct FeedDemoVerticalQualificationControls: View {
    let model: FeedDemoModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                qualificationButton(
                    title: "Normal",
                    identifier: "vertical-network-normal"
                ) {
                    await model.setQualificationNetworkCondition(.normal)
                }
                qualificationButton(
                    title: "Poor",
                    identifier: "vertical-network-poor"
                ) {
                    await model.setQualificationNetworkCondition(.poor)
                }
                qualificationButton(
                    title: "Offline",
                    identifier: "vertical-network-offline"
                ) {
                    await model.setQualificationNetworkCondition(.offline)
                }
            }
            HStack(spacing: 6) {
                qualificationButton(
                    title: "Pressure",
                    identifier: "vertical-memory-pressure"
                ) {
                    await model.handleQualificationMemoryPressure()
                }
                qualificationButton(
                    title: "Finish",
                    identifier: "vertical-qualification-finish"
                ) {
                    await model.finishVerticalQualification()
                }
            }
            qualificationValue(
                model.qualificationNetworkCondition.rawValue,
                identifier: "vertical-network-condition"
            )
            qualificationValue(
                model.engineSnapshot.activeItemID?.rawValue ?? "none",
                identifier: "vertical-active-item"
            )
            qualificationValue(
                model.engineSnapshot.audibleItemID?.rawValue ?? "none",
                identifier: "vertical-audible-item"
            )
            qualificationValue(
                String(model.metrics.cancellationCount),
                identifier: "vertical-cancellation-count"
            )
            qualificationValue(
                model.verticalQualificationReport?.json ?? "pending",
                identifier: "vertical-qualification-report"
            )
        }
        .padding(8)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
    }

    private func qualificationButton(
        title: LocalizedStringKey,
        identifier: String,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> some View {
        Button(title) {
            Task { await action() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier(identifier)
    }

    private func qualificationValue(_ value: String, identifier: String) -> some View {
        Text(verbatim: value)
            .font(.system(size: 1))
            .lineLimit(1)
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(value)
    }
}

private struct FeedDemoPrimaryContent: View {
    let model: FeedDemoModel

    var body: some View {
        ZStack {
            if let engine = model.engine {
                FeedDemoViewport(
                    entries: model.entries,
                    engine: engine,
                    snapshot: model.engineSnapshot,
                    focusedItemID: model.focusedItemID,
                    layout: model.selectedMode.layout,
                    onGeometryChange: model.observe,
                    onScrollGeometryChange: model.observe,
                    onFocusRequest: model.requestFocus
                )
                .ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [Color(red: 0.035, green: 0.04, blue: 0.075), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                FeedDemoLoadingView(status: model.status)
            }
        }
    }
}

private struct FeedDemoPrimaryChrome: View {
    let model: FeedDemoModel

    var body: some View {
        VStack(spacing: 10) {
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
            Text("iOS schedules tiny background warmups opportunistically.", bundle: #bundle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
                .accessibilityIdentifier("background-warming-disclosure")
            if model.usesColdOriginFallback {
                Text("Preferred demo port is busy; this launch uses a cold cache identity.", bundle: #bundle)
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .accessibilityIdentifier("cold-origin-fallback")
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
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .background {
            LinearGradient(
                colors: [.black.opacity(0.82), .black.opacity(0.5), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }
}

private struct FeedDemoPrimaryHUD: View {
    let entries: [FeedDemoEntry]
    let focusedItemID: FeedItemID?
    let focusedPlayback: HLSFeedPlayback?
    let metrics: FeedDemoMetrics
    let showsPageTitle: Bool
    let showsCredits: Bool
    let onOpenCredits: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsPageTitle, let entry = entries.first(where: { $0.id == focusedItemID }) {
                Text(entry.title).font(.headline).lineLimit(2)
                Text(entry.detail).font(.caption).foregroundStyle(.white.opacity(0.72))
            }
            HStack {
                Text(positionText)
                    .font(.caption.monospacedDigit().weight(.bold))
                Spacer()
                Text(playbackStatus.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(playbackStatus == .playing ? .mint : .white)
                    .accessibilityIdentifier("feed-focused-playback")
                    .accessibilityValue(playbackStatus.accessibilityValue)
                Text(verbatim: focusedItemID?.rawValue ?? "pending")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .accessibilityIdentifier("feed-focused-item")
                    .accessibilityValue(focusedItemID?.rawValue ?? "pending")
            }
            HStack(spacing: 12) {
                FeedDemoHUDMetric(
                    title: LocalizedStringResource("Players", bundle: #bundle),
                    value: "\(metrics.playerCount)/\(metrics.playerLimit)"
                )
                FeedDemoHUDMetric(
                    title: LocalizedStringResource("Handoffs", bundle: #bundle),
                    value: "\(metrics.handoffSuccessCount)"
                )
                FeedDemoHUDMetric(
                    title: LocalizedStringResource("Cache", bundle: #bundle),
                    value: metrics.cacheHitRate.map {
                        $0.formatted(.percent.precision(.fractionLength(0)))
                    } ?? "—"
                )
                FeedDemoHUDMetric(
                    title: LocalizedStringResource("Cancels", bundle: #bundle),
                    value: "\(metrics.acknowledgedCancellationCount)"
                )
            }
            if let attribution = entries.first(where: { $0.id == focusedItemID })?.attribution {
                Text(verbatim: attribution)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .accessibilityIdentifier("feed-media-attribution")
            }
            if showsCredits {
                Button(action: onOpenCredits) {
                    Label {
                        Text("Media credits", bundle: #bundle)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.caption.weight(.semibold))
                }
                .accessibilityIdentifier("media-credits-button")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var positionText: LocalizedStringResource {
        guard let focusedItemID,
              let index = entries.firstIndex(where: { $0.id == focusedItemID })
        else {
            return LocalizedStringResource("Preparing feed", bundle: #bundle)
        }
        return LocalizedStringResource(
            "Moment \(index + 1) of \(entries.count)",
            bundle: #bundle
        )
    }

    private var playbackStatus: PlaybackStatus {
        if focusedPlayback?.hasStartedPlayback == true { return .playing }
        return switch focusedPlayback?.phase {
        case .focused: .preparing
        case .warm: .ready
        case .loading: .preparing
        case .failed: .failed
        case nil: .queued
        }
    }

    private enum PlaybackStatus: Equatable {
        case playing
        case ready
        case preparing
        case failed
        case queued

        var title: LocalizedStringResource {
            switch self {
            case .playing: LocalizedStringResource("Playing", bundle: #bundle)
            case .ready: LocalizedStringResource("Ready", bundle: #bundle)
            case .preparing: LocalizedStringResource("Preparing", bundle: #bundle)
            case .failed: LocalizedStringResource("Failed", bundle: #bundle)
            case .queued: LocalizedStringResource("Queued", bundle: #bundle)
            }
        }

        var accessibilityValue: String {
            switch self {
            case .playing: "Playing"
            case .ready: "Ready"
            case .preparing: "Preparing"
            case .failed: "Failed"
            case .queued: "Queued"
            }
        }
    }
}

private struct FeedDemoHUDMetric: View {
    let title: LocalizedStringResource
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
            Text(verbatim: value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            FeedDemoLowPowerToggle(
                isEnabled: isLowPowerModeEnabled,
                onChange: onLowPowerChange
            )
        }
    }
}

private struct FeedDemoLowPowerToggle: View {
    let isEnabled: Bool
    let onChange: @MainActor @Sendable (Bool) -> Void

    var body: some View {
#if os(tvOS)
        toggle
#else
        toggle.toggleStyle(.button)
#endif
    }

    private var toggle: some View {
        Toggle(
            isOn: Binding(
                get: { isEnabled },
                set: { value in onChange(value) }
            )
        ) {
            Label {
                Text("Low power", bundle: #bundle)
            } icon: {
                Image(systemName: "leaf.fill")
            }
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("low-power-toggle")
        .accessibilityLabel(Text("Low power", bundle: #bundle))
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
    let onScrollGeometryChange: (FeedDemoScrollGeometrySample) -> Void
    let onFocusRequest: (FeedItemID) -> Void

    var body: some View {
        GeometryReader { proxy in
            let viewport = CGRect(origin: .zero, size: proxy.size)
            switch layout {
            case .paged:
                if #available(iOS 18, macOS 15, tvOS 18, visionOS 2, *) {
                    FeedDemoModernPagedScroller(
                        entries: entries,
                        engine: engine,
                        snapshot: snapshot,
                        focusedItemID: focusedItemID,
                        onScrollGeometryChange: onScrollGeometryChange,
                        onFocusRequest: onFocusRequest
                    )
                    .id(entries.first?.id)
                } else {
                    FeedDemoLegacyPagedScroller(
                        entries: entries,
                        engine: engine,
                        snapshot: snapshot,
                        focusedItemID: focusedItemID,
                        viewportHeight: proxy.size.height,
                        viewport: viewport,
                        onGeometryChange: onGeometryChange,
                        onFocusRequest: onFocusRequest
                    )
                    .id(entries.first?.id)
                }
            case .windowed:
                FeedDemoWindowedScroller(
                    entries: entries,
                    engine: engine,
                    snapshot: snapshot,
                    focusedItemID: focusedItemID,
                    viewportHeight: proxy.size.height,
                    onFocusRequest: onFocusRequest
                )
                .coordinateSpace(name: "HLSFeedViewport")
                .onPreferenceChange(FeedDemoFramePreferenceKey.self) { frames in
                    onGeometryChange(frames, viewport)
                }
            }
        }
    }
}

@available(iOS 18, macOS 15, tvOS 18, visionOS 2, *)
private struct FeedDemoModernPagedScroller: View {
    @State private var scrollPositionID: FeedItemID?

    let entries: [FeedDemoEntry]
    let engine: HLSFeedEngine
    let snapshot: HLSFeedEngineSnapshot
    let focusedItemID: FeedItemID?
    let onScrollGeometryChange: (FeedDemoScrollGeometrySample) -> Void
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
                        cornerRadius: 0,
                        contentBottomPadding: 128,
                        showsTopStatus: false,
                        onFocusRequest: onFocusRequest
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(entry.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollPositionID, anchor: .center)
        .scrollIndicators(.hidden)
        .background(.black)
        .onAppear {
            scrollPositionID = focusedItemID ?? entries.first?.id
        }
        .onChange(of: scrollPositionID) { _, itemID in
            if let itemID { onFocusRequest(itemID) }
        }
        .onScrollGeometryChange(for: FeedDemoScrollGeometrySample.self) { geometry in
            FeedDemoScrollGeometrySample(
                contentOffsetY: geometry.visibleRect.minY,
                viewportSize: geometry.containerSize
            )
        } action: { _, sample in
            onScrollGeometryChange(sample)
        }
        .accessibilityIdentifier("primary-vertical-feed")
    }
}

private struct FeedDemoLegacyPagedScroller: View {
    @State private var scrollPositionID: FeedItemID?

    let entries: [FeedDemoEntry]
    let engine: HLSFeedEngine
    let snapshot: HLSFeedEngineSnapshot
    let focusedItemID: FeedItemID?
    let viewportHeight: CGFloat
    let viewport: CGRect
    let onGeometryChange: ([FeedItemID: CGRect], CGRect) -> Void
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
                        cornerRadius: 0,
                        contentBottomPadding: 128,
                        showsTopStatus: false,
                        onFocusRequest: onFocusRequest
                    )
                    .frame(height: viewportHeight)
                    .feedDemoGeometry(itemID: entry.id)
                    .id(entry.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollPositionID, anchor: .center)
        .scrollIndicators(.hidden)
        .background(.black)
        .coordinateSpace(name: "HLSFeedViewport")
        .onPreferenceChange(FeedDemoFramePreferenceKey.self) { frames in
            onGeometryChange(frames, viewport)
        }
        .onAppear {
            scrollPositionID = focusedItemID ?? entries.first?.id
        }
        .onChange(of: scrollPositionID) { _, itemID in
            if let itemID { onFocusRequest(itemID) }
        }
        .accessibilityIdentifier("primary-vertical-feed")
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
                        cornerRadius: 20,
                        contentBottomPadding: 18,
                        showsTopStatus: true,
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
    let cornerRadius: CGFloat
    let contentBottomPadding: CGFloat
    let showsTopStatus: Bool
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
                if showsTopStatus {
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
                }
                Spacer()
                if showsTopStatus {
                    Text(entry.title)
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    Text(entry.detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, contentBottomPadding)
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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

import Foundation
import Observation
import ProxyPlayerKit
import SwiftUI

enum FeedDemoAnalyticsLayer: String, CaseIterable, Equatable, Sendable {
    case avFoundation
    case proxyOrigin
    case engine
    case exporter
}

struct FeedDemoAnalyticsLayerCounts: Equatable, Sendable {
    private(set) var avFoundation: UInt64 = 0
    private(set) var proxyOrigin: UInt64 = 0
    private(set) var engine: UInt64 = 0
    private(set) var exporter: UInt64 = 0

    subscript(layer: FeedDemoAnalyticsLayer) -> UInt64 {
        switch layer {
        case .avFoundation: avFoundation
        case .proxyOrigin: proxyOrigin
        case .engine: engine
        case .exporter: exporter
        }
    }

    mutating func increment(_ layer: FeedDemoAnalyticsLayer) {
        switch layer {
        case .avFoundation:
            avFoundation = Self.saturatingAdd(avFoundation, 1)
        case .proxyOrigin:
            proxyOrigin = Self.saturatingAdd(proxyOrigin, 1)
        case .engine:
            engine = Self.saturatingAdd(engine, 1)
        case .exporter:
            exporter = Self.saturatingAdd(exporter, 1)
        }
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

struct FeedDemoAnalyticsEventRow: Identifiable, Equatable, Sendable {
    let id: String
    let layer: FeedDemoAnalyticsLayer
    let source: String
    let lifecycle: String
    let priority: String
    let elapsedMilliseconds: UInt64
    let measurementSummary: String
}

struct FeedDemoAnalyticsSummarySnapshot: Equatable, Sendable {
    let terminalReason: String
    let durationMilliseconds: UInt64
    let measurementSummary: String
}

struct FeedDemoAnalyticsDeliveryHealth: Equatable, Sendable {
    static let empty = Self(
        isAcceptingRecords: false,
        isDelivering: false,
        queuedRecordCount: 0,
        queuedBytes: 0,
        maximumQueuedRecordCount: 0,
        memoryBudgetBytes: 0,
        spooledRecordCount: 0,
        spooledBytes: 0,
        deliveredRecordCount: 0,
        droppedRecordCount: 0,
        retryCount: 0,
        exportFailureCount: 0,
        activeTaskCount: 0,
        taskLimit: 0
    )

    let isAcceptingRecords: Bool
    let isDelivering: Bool
    let queuedRecordCount: Int
    let queuedBytes: Int
    let maximumQueuedRecordCount: Int
    let memoryBudgetBytes: Int
    let spooledRecordCount: Int
    let spooledBytes: Int
    let deliveredRecordCount: UInt64
    let droppedRecordCount: UInt64
    let retryCount: UInt64
    let exportFailureCount: UInt64
    let activeTaskCount: Int
    let taskLimit: Int

    init(_ snapshot: PlaybackAnalyticsDelivery.Snapshot) {
        self.init(
            isAcceptingRecords: snapshot.isAcceptingRecords,
            isDelivering: snapshot.isDelivering,
            queuedRecordCount: snapshot.queuedRecordCount,
            queuedBytes: snapshot.queuedBytes,
            maximumQueuedRecordCount: snapshot.maximumQueuedRecordCount,
            memoryBudgetBytes: snapshot.memoryBudgetBytes,
            spooledRecordCount: snapshot.spooledRecordCount,
            spooledBytes: snapshot.spooledBytes,
            deliveredRecordCount: snapshot.deliveredRecordCount,
            droppedRecordCount: Self.saturatingSum(
                snapshot.droppedRoutineRecordCount,
                snapshot.droppedImportantRecordCount,
                snapshot.droppedCriticalRecordCount
            ),
            retryCount: snapshot.retryCount,
            exportFailureCount: snapshot.exportFailureCount,
            activeTaskCount: snapshot.activeTaskCount,
            taskLimit: snapshot.taskLimit
        )
    }

    private init(
        isAcceptingRecords: Bool,
        isDelivering: Bool,
        queuedRecordCount: Int,
        queuedBytes: Int,
        maximumQueuedRecordCount: Int,
        memoryBudgetBytes: Int,
        spooledRecordCount: Int,
        spooledBytes: Int,
        deliveredRecordCount: UInt64,
        droppedRecordCount: UInt64,
        retryCount: UInt64,
        exportFailureCount: UInt64,
        activeTaskCount: Int,
        taskLimit: Int
    ) {
        self.isAcceptingRecords = isAcceptingRecords
        self.isDelivering = isDelivering
        self.queuedRecordCount = queuedRecordCount
        self.queuedBytes = queuedBytes
        self.maximumQueuedRecordCount = maximumQueuedRecordCount
        self.memoryBudgetBytes = memoryBudgetBytes
        self.spooledRecordCount = spooledRecordCount
        self.spooledBytes = spooledBytes
        self.deliveredRecordCount = deliveredRecordCount
        self.droppedRecordCount = droppedRecordCount
        self.retryCount = retryCount
        self.exportFailureCount = exportFailureCount
        self.activeTaskCount = activeTaskCount
        self.taskLimit = taskLimit
    }

    private static func saturatingSum(_ values: UInt64...) -> UInt64 {
        values.reduce(0) { partial, value in
            let result = partial.addingReportingOverflow(value)
            return result.overflow ? .max : result.partialValue
        }
    }
}

@Observable
@MainActor
final class FeedDemoAnalyticsInspector {
    static let maximumRecentEventCount = 20
    static let maximumPreviewRecordCount = 4
    static let maximumPreviewBytes = 16 * 1_024

    private(set) var mode: FeedDemoMode = .shortForm
    private(set) var activeAttemptCount = 0
    private(set) var maximumActiveAttemptCount = 0
    private(set) var emittedEventCount: UInt64 = 0
    private(set) var droppedEventCount: UInt64 = 0
    private(set) var emittedSummaryCount: UInt64 = 0
    private(set) var droppedSummaryCount: UInt64 = 0
    private(set) var staleEventCount: UInt64 = 0
    private(set) var evictedAttemptCount: UInt64 = 0
    private(set) var lastSequence: UInt64 = 0
    private(set) var layerCounts = FeedDemoAnalyticsLayerCounts()
    private(set) var recentEvents: [FeedDemoAnalyticsEventRow] = []
    private(set) var latestSummary: FeedDemoAnalyticsSummarySnapshot?
    private(set) var deliveryHealth = FeedDemoAnalyticsDeliveryHealth.empty
    private(set) var exportPreview = ""
    private(set) var exportPreviewBytes = 0

    @ObservationIgnored private var previewRecords: [PlaybackAnalyticsRecord] = []

    func reset(
        for mode: FeedDemoMode,
        timelineSnapshot: PlaybackAnalyticsTimeline.Snapshot = .empty
    ) {
        self.mode = mode
        update(timeline: timelineSnapshot)
        layerCounts = FeedDemoAnalyticsLayerCounts()
        recentEvents.removeAll(keepingCapacity: true)
        latestSummary = nil
        deliveryHealth = .empty
        previewRecords.removeAll(keepingCapacity: true)
        exportPreview = ""
        exportPreviewBytes = 0
    }

    func record(
        _ event: PlaybackAnalytics.Event,
        timelineSnapshot: PlaybackAnalyticsTimeline.Snapshot
    ) {
        update(timeline: timelineSnapshot)
        let layer = Self.layer(for: event.source)
        layerCounts.increment(layer)
        recentEvents.append(Self.row(for: event, layer: layer))
        if recentEvents.count > Self.maximumRecentEventCount {
            recentEvents.removeFirst(recentEvents.count - Self.maximumRecentEventCount)
        }
        appendPreview(.event(event))
    }

    func record(
        _ summary: PlaybackAnalytics.Summary,
        timelineSnapshot: PlaybackAnalyticsTimeline.Snapshot
    ) {
        update(timeline: timelineSnapshot)
        latestSummary = Self.summarySnapshot(for: summary)
        appendPreview(.summary(summary))
    }

    func update(delivery snapshot: PlaybackAnalyticsDelivery.Snapshot) {
        deliveryHealth = FeedDemoAnalyticsDeliveryHealth(snapshot)
    }

    private func update(timeline snapshot: PlaybackAnalyticsTimeline.Snapshot) {
        activeAttemptCount = snapshot.activeAttemptCount
        maximumActiveAttemptCount = snapshot.maximumActiveAttemptCount
        emittedEventCount = snapshot.emittedEventCount
        droppedEventCount = snapshot.droppedEventCount
        emittedSummaryCount = snapshot.emittedSummaryCount
        droppedSummaryCount = snapshot.droppedSummaryCount
        staleEventCount = snapshot.staleEventCount
        evictedAttemptCount = snapshot.evictedAttemptCount
        lastSequence = snapshot.lastSequence
    }

    private func appendPreview(_ record: PlaybackAnalyticsRecord) {
        previewRecords.append(record)
        if previewRecords.count > Self.maximumPreviewRecordCount {
            previewRecords.removeFirst(previewRecords.count - Self.maximumPreviewRecordCount)
        }

        var candidate = previewRecords
        while !candidate.isEmpty {
            guard let data = try? PlaybackAnalyticsExportCodec.encodeJSONLines(
                .init(records: candidate)
            ) else {
                exportPreview = ""
                exportPreviewBytes = 0
                return
            }
            if data.count <= Self.maximumPreviewBytes {
                previewRecords = candidate
                exportPreview = String(decoding: data, as: UTF8.self)
                exportPreviewBytes = data.count
                return
            }
            candidate.removeFirst()
        }
        previewRecords.removeAll(keepingCapacity: true)
        exportPreview = ""
        exportPreviewBytes = 0
    }

    private static func row(
        for event: PlaybackAnalytics.Event,
        layer: FeedDemoAnalyticsLayer
    ) -> FeedDemoAnalyticsEventRow {
        FeedDemoAnalyticsEventRow(
            id: event.recordID.encodedValue,
            layer: layer,
            source: token(for: event.source),
            lifecycle: token(for: event.lifecycle),
            priority: event.priority.rawValue,
            elapsedMilliseconds: event.timestamp.elapsedNanoseconds / 1_000_000,
            measurementSummary: measurementSummary(event.measurements)
        )
    }

    private static func summarySnapshot(
        for summary: PlaybackAnalytics.Summary
    ) -> FeedDemoAnalyticsSummarySnapshot {
        let elapsed = summary.endedAt.elapsedNanoseconds >= summary.startedAt.elapsedNanoseconds
            ? summary.endedAt.elapsedNanoseconds - summary.startedAt.elapsedNanoseconds
            : 0
        return FeedDemoAnalyticsSummarySnapshot(
            terminalReason: token(for: summary.terminalReason),
            durationMilliseconds: elapsed / 1_000_000,
            measurementSummary: measurementSummary(summary.measurements)
        )
    }

    private static func measurementSummary(
        _ measurements: [PlaybackAnalytics.Measurement]
    ) -> String {
        guard !measurements.isEmpty else { return "none" }
        return measurements.prefix(4).map { measurement in
            let value = measurement.value.formatted(
                .number.precision(.fractionLength(0...3))
            )
            return "\(measurement.name.encodedValue)=\(value) \(token(for: measurement.unit))"
        }.joined(separator: " · ")
    }

    private static func layer(
        for source: PlaybackAnalytics.Source
    ) -> FeedDemoAnalyticsLayer {
        switch source {
        case .player, .avFoundation:
            .avFoundation
        case .localProxy, .origin, .cache:
            .proxyOrigin
        case .feedEngine, .scheduler:
            .engine
        case .exporter, .unknown:
            .exporter
        }
    }

    private static func token(for source: PlaybackAnalytics.Source) -> String {
        switch source {
        case .feedEngine: "feed_engine"
        case .player: "player"
        case .avFoundation: "av_foundation"
        case .localProxy: "local_proxy"
        case .origin: "origin"
        case .cache: "cache"
        case .scheduler: "scheduler"
        case .exporter: "exporter"
        case .unknown(let value): "unknown_\(value)"
        }
    }

    private static func token(for lifecycle: PlaybackAnalytics.Lifecycle) -> String {
        switch lifecycle {
        case .sessionStarted: "session_started"
        case .focusRequested: "focus_requested"
        case .preparing: "preparing"
        case .ready: "ready"
        case .playbackStarted: "playback_started"
        case .paused: "paused"
        case .resumed: "resumed"
        case .seekStarted: "seek_started"
        case .seekCompleted: "seek_completed"
        case .stalled: "stalled"
        case .recovered: "recovered"
        case .rateChanged: "rate_changed"
        case .variantSwitchStarted: "variant_switch_started"
        case .variantSwitched: "variant_switched"
        case .resourceRequested: "resource_requested"
        case .resourceCompleted: "resource_completed"
        case .liveEdgeChanged: "live_edge_changed"
        case .stitchedBoundary: "stitched_boundary"
        case .handoffStarted: "handoff_started"
        case .handoffCompleted: "handoff_completed"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .backgrounded: "backgrounded"
        case .summaryEmitted: "summary_emitted"
        case .unknown(let value): "unknown_\(value)"
        }
    }

    private static func token(for reason: PlaybackAnalytics.TerminalReason) -> String {
        switch reason {
        case .completed: "completed"
        case .abandonedBeforeStart: "abandoned_before_start"
        case .cancelled: "cancelled"
        case .backgrounded: "backgrounded"
        case .crashed: "crashed"
        case .failed: "failed"
        case .incomplete: "incomplete"
        case .interrupted: "interrupted"
        case .unknown(let value): "unknown_\(value)"
        }
    }

    private static func token(for unit: PlaybackAnalytics.MeasurementUnit) -> String {
        switch unit {
        case .nanoseconds: "ns"
        case .milliseconds: "ms"
        case .seconds: "s"
        case .bytes: "bytes"
        case .bitsPerSecond: "bit/s"
        case .count: "count"
        case .ratio: "ratio"
        case .scalar: "scalar"
        case .unknown(let value): value
        }
    }
}

struct FeedDemoAnalyticsLauncher: View {
    let inspector: FeedDemoAnalyticsInspector
    let onOpen: @MainActor @Sendable () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Inspect analytics", bundle: #bundle)
                        .font(.subheadline.weight(.semibold))
                    Text(
                        "\(inspector.emittedEventCount) events · \(inspector.emittedSummaryCount) summaries",
                        bundle: #bundle,
                        comment: "Analytics inspector launcher; the first number is events and the second is summaries."
                    )
                    .font(.caption2.monospacedDigit())
                    .accessibilityIdentifier("analytics-launcher-event-count")
                    .accessibilityValue(String(inspector.emittedEventCount))
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("analytics-inspector-button")
    }
}

struct FeedDemoAnalyticsInspectorView: View {
    let inspector: FeedDemoAnalyticsInspector
    let onClose: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PLAYBACK ANALYTICS", bundle: #bundle)
                        .font(.caption.weight(.black))
                        .tracking(1.5)
                        .foregroundStyle(.mint)
                    Text("Live inspector", bundle: #bundle)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                }
                Spacer()
                Button(action: onClose) {
                    Label {
                        Text("Close", bundle: #bundle)
                    } icon: {
                        Image(systemName: "xmark.circle.fill")
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("analytics-inspector-close")
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FeedDemoAnalyticsOverviewSection(
                        mode: inspector.mode,
                        activeAttemptCount: inspector.activeAttemptCount,
                        maximumActiveAttemptCount: inspector.maximumActiveAttemptCount,
                        emittedEventCount: inspector.emittedEventCount,
                        droppedEventCount: inspector.droppedEventCount,
                        emittedSummaryCount: inspector.emittedSummaryCount,
                        droppedSummaryCount: inspector.droppedSummaryCount,
                        staleEventCount: inspector.staleEventCount,
                        evictedAttemptCount: inspector.evictedAttemptCount,
                        layerCounts: inspector.layerCounts
                    )
                    FeedDemoAnalyticsTimelineSection(events: inspector.recentEvents)
                    FeedDemoAnalyticsSummarySection(summary: inspector.latestSummary)
                    FeedDemoAnalyticsDeliverySection(health: inspector.deliveryHealth)
                    FeedDemoAnalyticsExportSection(
                        preview: inspector.exportPreview,
                        byteCount: inspector.exportPreviewBytes
                    )
                }
                .padding([.horizontal, .bottom])
            }
            .accessibilityIdentifier("analytics-inspector")
        }
        .background(Color(red: 0.025, green: 0.03, blue: 0.055).ignoresSafeArea())
        .tint(.mint)
    }
}

private struct FeedDemoAnalyticsOverviewSection: View {
    let mode: FeedDemoMode
    let activeAttemptCount: Int
    let maximumActiveAttemptCount: Int
    let emittedEventCount: UInt64
    let droppedEventCount: UInt64
    let emittedSummaryCount: UInt64
    let droppedSummaryCount: UInt64
    let staleEventCount: UInt64
    let evictedAttemptCount: UInt64
    let layerCounts: FeedDemoAnalyticsLayerCounts

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedDemoAnalyticsSectionTitle(
                title: LocalizedStringResource("Current session", bundle: #bundle),
                symbolName: "chart.xyaxis.line"
            )
            HStack(spacing: 8) {
                FeedDemoAnalyticsValueTile(
                    title: LocalizedStringResource("Mode", bundle: #bundle),
                    value: mode.rawValue,
                    identifier: "analytics-mode"
                )
                FeedDemoAnalyticsValueTile(
                    title: LocalizedStringResource("Attempts", bundle: #bundle),
                    value: "\(activeAttemptCount)/\(maximumActiveAttemptCount)",
                    identifier: "analytics-active-attempts"
                )
                FeedDemoAnalyticsValueTile(
                    title: LocalizedStringResource("Events", bundle: #bundle),
                    value: String(emittedEventCount),
                    identifier: "analytics-event-count"
                )
                FeedDemoAnalyticsValueTile(
                    title: LocalizedStringResource("Summaries", bundle: #bundle),
                    value: String(emittedSummaryCount),
                    identifier: "analytics-summary-count"
                )
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
                spacing: 8
            ) {
                ForEach(FeedDemoAnalyticsLayer.allCases, id: \.rawValue) { layer in
                    FeedDemoAnalyticsLayerTile(
                        layer: layer,
                        count: layerCounts[layer]
                    )
                }
            }
            Text(
                "Dropped \(droppedEventCount) events · \(droppedSummaryCount) summaries · \(staleEventCount) stale · \(evictedAttemptCount) evicted",
                bundle: #bundle,
                comment: "Analytics bounds; numbers are dropped events, dropped summaries, stale events, and evicted attempts."
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("analytics-timeline-bounds")
        }
        .feedDemoAnalyticsSection()
    }
}

private struct FeedDemoAnalyticsTimelineSection: View {
    let events: [FeedDemoAnalyticsEventRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedDemoAnalyticsSectionTitle(
                title: LocalizedStringResource("Recent timeline", bundle: #bundle),
                symbolName: "list.bullet.rectangle"
            )
            if events.isEmpty {
                Text("Waiting for the first playback signal…", bundle: #bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    FeedDemoAnalyticsEventView(event: event)
                }
            }
        }
        .feedDemoAnalyticsSection()
        .accessibilityIdentifier("analytics-timeline")
    }
}

private struct FeedDemoAnalyticsEventView: View {
    let event: FeedDemoAnalyticsEventRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(verbatim: event.lifecycle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(verbatim: "+\(event.elapsedMilliseconds)ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: "\(event.source) · \(event.priority)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(color)
                Text(verbatim: event.measurementSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private var symbolName: String {
        switch event.layer {
        case .avFoundation: "play.rectangle.on.rectangle.fill"
        case .proxyOrigin: "network"
        case .engine: "gearshape.2.fill"
        case .exporter: "arrow.up.doc.fill"
        }
    }

    private var color: Color {
        switch event.layer {
        case .avFoundation: .cyan
        case .proxyOrigin: .orange
        case .engine: .mint
        case .exporter: .purple
        }
    }
}

private struct FeedDemoAnalyticsSummarySection: View {
    let summary: FeedDemoAnalyticsSummarySnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedDemoAnalyticsSectionTitle(
                title: LocalizedStringResource("Terminal summary", bundle: #bundle),
                symbolName: "checkmark.seal.fill"
            )
            if let summary {
                Text(verbatim: summary.terminalReason)
                    .font(.headline.monospaced())
                    .foregroundStyle(.white)
                Text(verbatim: "\(summary.durationMilliseconds)ms · \(summary.measurementSummary)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            } else {
                Text("No playback attempt has ended yet.", bundle: #bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .feedDemoAnalyticsSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analytics-summary-status")
        .accessibilityValue(summary?.terminalReason ?? "pending")
    }
}

private struct FeedDemoAnalyticsDeliverySection: View {
    let health: FeedDemoAnalyticsDeliveryHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedDemoAnalyticsSectionTitle(
                title: LocalizedStringResource("Queue and backpressure", bundle: #bundle),
                symbolName: "gauge.with.dots.needle.50percent"
            )
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
                spacing: 8
            ) {
                FeedDemoAnalyticsValueTile(
                    title: LocalizedStringResource("Queue", bundle: #bundle),
                    value: "\(health.queuedRecordCount)/\(health.maximumQueuedRecordCount)",
                    identifier: "analytics-queue-depth"
                )
                FeedDemoAnalyticsValueTile(
                    title: LocalizedStringResource("Memory", bundle: #bundle),
                    value: "\(health.queuedBytes)/\(health.memoryBudgetBytes) B",
                    identifier: "analytics-queue-bytes"
                )
                FeedDemoAnalyticsValueTile(
                    title: LocalizedStringResource("Delivered", bundle: #bundle),
                    value: String(health.deliveredRecordCount),
                    identifier: "analytics-delivered-count"
                )
                FeedDemoAnalyticsValueTile(
                    title: LocalizedStringResource("Dropped", bundle: #bundle),
                    value: String(health.droppedRecordCount),
                    identifier: "analytics-dropped-count"
                )
            }
            Text(
                "Spool \(health.spooledRecordCount) records / \(health.spooledBytes) B · retries \(health.retryCount) · failures \(health.exportFailureCount) · tasks \(health.activeTaskCount)/\(health.taskLimit)",
                bundle: #bundle,
                comment: "Analytics delivery health; numbers are spool records/bytes, retries, failures, active tasks, and task limit."
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .feedDemoAnalyticsSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analytics-delivery-health")
        .accessibilityValue(
            "queue=\(health.queuedRecordCount);dropped=\(health.droppedRecordCount);tasks=\(health.activeTaskCount)"
        )
    }
}

private struct FeedDemoAnalyticsExportSection: View {
    let preview: String
    let byteCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedDemoAnalyticsSectionTitle(
                title: LocalizedStringResource("Sanitized export preview", bundle: #bundle),
                symbolName: "doc.text.magnifyingglass"
            )
            Text(
                "Canonical JSON Lines · \(byteCount) bytes",
                bundle: #bundle,
                comment: "Analytics export preview size in bytes."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if preview.isEmpty {
                Text("No records yet.", bundle: #bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    Text(verbatim: preview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .feedDemoAnalyticsSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analytics-export-preview")
        .accessibilityValue(preview.isEmpty ? "pending" : preview)
    }
}

private struct FeedDemoAnalyticsLayerTile: View {
    let layer: FeedDemoAnalyticsLayer
    let count: UInt64

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(.mint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(verbatim: String(count))
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            .white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("analytics-layer-\(layer.rawValue)")
        .accessibilityValue(String(count))
    }

    private var title: LocalizedStringResource {
        switch layer {
        case .avFoundation: LocalizedStringResource("AVFoundation", bundle: #bundle)
        case .proxyOrigin: LocalizedStringResource("Proxy + origin", bundle: #bundle)
        case .engine: LocalizedStringResource("Feed engine", bundle: #bundle)
        case .exporter: LocalizedStringResource("Exporter", bundle: #bundle)
        }
    }

    private var symbolName: String {
        switch layer {
        case .avFoundation: "play.rectangle.on.rectangle.fill"
        case .proxyOrigin: "network"
        case .engine: "gearshape.2.fill"
        case .exporter: "arrow.up.doc.fill"
        }
    }
}

private struct FeedDemoAnalyticsValueTile: View {
    let title: LocalizedStringResource
    let value: String
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            .white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
        .accessibilityValue(value)
    }
}

private struct FeedDemoAnalyticsSectionTitle: View {
    let title: LocalizedStringResource
    let symbolName: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbolName)
        }
        .font(.headline)
        .foregroundStyle(.white)
    }
}

private extension View {
    func feedDemoAnalyticsSection() -> some View {
        padding(12)
            .background(
                .white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}

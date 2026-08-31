import Foundation
import HLSCore
import ProxyPlayerKit

enum FeedDemoLayout: Sendable {
    case paged
    case windowed
}

enum FeedDemoMode: String, CaseIterable, Identifiable, Sendable {
    case shortForm
    case paged
    case continuous
    case longForm
    case liveDVR
    case offlineFirst
    case looping
    case stitched

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .shortForm: LocalizedStringResource("Short form", bundle: #bundle)
        case .paged: LocalizedStringResource("Paged", bundle: #bundle)
        case .continuous: LocalizedStringResource("Continuous", bundle: #bundle)
        case .longForm: LocalizedStringResource("Long form", bundle: #bundle)
        case .liveDVR: LocalizedStringResource("Live + DVR", bundle: #bundle)
        case .offlineFirst: LocalizedStringResource("Offline first", bundle: #bundle)
        case .looping: LocalizedStringResource("Looping", bundle: #bundle)
        case .stitched: LocalizedStringResource("Stitched", bundle: #bundle)
        }
    }

    var symbolName: String {
        switch self {
        case .shortForm: "bolt.fill"
        case .paged: "rectangle.stack.fill"
        case .continuous: "scroll.fill"
        case .longForm: "film.fill"
        case .liveDVR: "dot.radiowaves.left.and.right"
        case .offlineFirst: "arrow.down.circle.fill"
        case .looping: "repeat"
        case .stitched: "link"
        }
    }

    var layout: FeedDemoLayout {
        switch self {
        case .continuous: .windowed
        default: .paged
        }
    }

    var policy: FeedPlaybackPolicy {
        switch self {
        case .shortForm:
            .preset(.shortFormFeed)
        case .paged, .stitched:
            .preset(.pagedFeed)
        case .continuous:
            .preset(.continuousWindowedFeed)
        case .longForm:
            .preset(.longForm)
        case .liveDVR:
            .preset(.live)
        case .offlineFirst:
            .preset(.offlineFirst)
        case .looping:
            {
                var policy = FeedPlaybackPolicy.preset(.shortFormFeed)
                policy.looping = .focusedItem
                return policy
            }()
        }
    }
}

struct FeedDemoEntry: Identifiable, Sendable {
    let id: FeedItemID
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let item: FeedPlaybackItem
    let accentIndex: Int
    var attribution: String? = nil
}

/// Stable, ordered fixture identities shared by the demo catalog and its
/// loopback origin. Each identity receives its own URL namespace even though
/// the tiny checked-in media fragments are intentionally reused.
enum FeedDemoFixtureCatalog {
    struct ShortItem: Sendable {
        let index: Int
        let fixtureID: String
        let sourceFixture: String
        let segmentCount: Int
        let title: String

        var estimatedByteCount: Int {
            segmentCount == 2 ? 384 * 1_024 : 512 * 1_024
        }
    }

    static let shortItems: [ShortItem] = {
        let titles = [
            "Violet rush", "Blue hour", "Neon crossing", "Coastal light",
            "City pulse", "Afterglow", "Night current", "Open road",
            "Electric sky", "Quiet motion", "Color drift", "Fast lane",
            "Golden frame", "Midnight loop", "Daybreak", "Signal bloom",
            "Soft focus", "Parallel lines", "Bright turn", "Last light",
            "New horizon", "Moving color", "Small wonder", "One more",
        ]
        return titles.enumerated().map { index, title in
            ShortItem(
                index: index,
                fixtureID: String(format: "feed-%02d", index + 1),
                sourceFixture: index.isMultiple(of: 2) ? "short-a" : "short-b",
                segmentCount: index.isMultiple(of: 3) ? 2 : 3,
                title: title
            )
        }
    }()
}

enum FeedDemoCatalog {
    static func entries(
        for mode: FeedDemoMode, baseURL: URL, library: FeedDemoMediaLibrary?
    ) throws -> [FeedDemoEntry] {
        guard let library else { return syntheticEntries(for: mode, baseURL: baseURL) }
        let root = baseURL.appendingPathComponent(library.catalog.corpusVersion)
        func entry(_ clip: FeedDemoMediaLibrary.Clip, id: String, index: Int) -> FeedDemoEntry {
            let rendition = clip.renditions.first { $0.id == "360p" }
            let startupPaths = rendition.map { [$0.initializationPath] + $0.segmentPaths.prefix(2) } ?? []
            let bytes = startupPaths.reduce(0) { $0 + (library.resourcesByPath[$1]?.byteCount ?? 0) }
            return FeedDemoEntry(
                id: FeedItemID(rawValue: id),
                title: LocalizedStringResource("\(clip.title)", bundle: #bundle),
                detail: LocalizedStringResource("\(Int(clip.duration))-second recorded audiovisual excerpt", bundle: #bundle),
                item: FeedPlaybackItem(
                    id: FeedItemID(rawValue: id),
                    source: .stream(url: root.appendingPathComponent(clip.masterPath), kind: .videoOnDemand),
                    estimatedPreparationBytes: bytes
                ),
                accentIndex: index,
                attribution: library.catalog.sources.first { $0.id == clip.sourceID }?.credit
            )
        }
        switch mode {
        case .shortForm, .paged, .continuous, .offlineFirst:
            let prefix: String
            let count: Int
            switch mode {
            case .paged: prefix = "page"; count = 20
            case .continuous: prefix = "window"; count = 24
            case .offlineFirst: prefix = "offline"; count = 20
            default: prefix = "short"; count = 24
            }
            return library.shortClips.prefix(count).enumerated().map {
                entry($0.element, id: "\(prefix)-\($0.offset)", index: $0.offset)
            }
        case .longForm:
            guard let clip = library.continuousClip else {
                throw FeedDemoMediaLibrary.ValidationError.invalid("continuous clip missing")
            }
            return [entry(clip, id: "long-form", index: 2)]
        case .looping:
            guard let clip = library.shortClips.first else {
                throw FeedDemoMediaLibrary.ValidationError.invalid("loop clip missing")
            }
            return [entry(clip, id: "looping-short", index: 4)]
        case .liveDVR:
            return [FeedDemoEntry(
                id: "live-window",
                title: LocalizedStringResource("Simulated live window", bundle: #bundle),
                detail: LocalizedStringResource("Prerecorded footage • moving 12-second DVR window", bundle: #bundle),
                item: FeedPlaybackItem(
                    id: "live-window",
                    source: .stream(url: root.appendingPathComponent("live/playlist.m3u8"), kind: .live),
                    estimatedPreparationBytes: 512 * 1_024
                ),
                accentIndex: 3,
                attribution: library.catalog.sources.first { $0.id == library.continuousClip?.sourceID }?.credit
            )]
        case .stitched:
            let clips = try library.shortClips.prefix(2).map { clip -> ProxyPlaybackClip in
                guard let rendition = clip.renditions.first(where: { $0.id == "360p" }) else {
                    throw FeedDemoMediaLibrary.ValidationError.invalid("stitching rendition missing")
                }
                return ProxyPlaybackClip(
                    id: clip.id,
                    playlistURL: root.appendingPathComponent(rendition.playlistPath),
                    mediaSignature: HLSClipMediaSignature(
                        container: .fragmentedMP4,
                        codecs: [rendition.videoCodec, rendition.audioCodec],
                        tracks: [
                            .init(kind: .video, codec: rendition.videoCodec),
                            .init(kind: .audio, codec: rendition.audioCodec, layout: rendition.audioLayout),
                        ],
                        videoRange: rendition.videoRange,
                        segmentsAreIndependent: true
                    )
                )
            }
            return [FeedDemoEntry(
                id: "stitched-a-b",
                title: LocalizedStringResource("Two real clips, one timeline", bundle: #bundle),
                detail: LocalizedStringResource("Original synchronized sound • explicit decoder compatibility", bundle: #bundle),
                item: FeedPlaybackItem(id: "stitched-a-b", source: .compatibleClips(clips), estimatedPreparationBytes: 1_024 * 1_024),
                accentIndex: 5,
                attribution: "NASA • Blender Foundation / www.bigbuckbunny.org"
            )]
        }
    }

    private static func syntheticEntries(for mode: FeedDemoMode, baseURL: URL) -> [FeedDemoEntry] {
        switch mode {
        case .shortForm:
            return shortEntries(
                fixtures: FeedDemoFixtureCatalog.shortItems,
                prefix: "short",
                baseURL: baseURL
            )
        case .paged:
            return shortEntries(
                fixtures: Array(FeedDemoFixtureCatalog.shortItems.prefix(20)),
                prefix: "page",
                baseURL: baseURL
            )
        case .continuous:
            return shortEntries(
                fixtures: FeedDemoFixtureCatalog.shortItems,
                prefix: "window",
                baseURL: baseURL
            )
        case .longForm:
            return [streamEntry(
                id: "long-form",
                fixture: "long-form",
                title: LocalizedStringResource("Eight-second feature", bundle: #bundle),
                detail: LocalizedStringResource("Long-form buffering policy", bundle: #bundle),
                kind: .videoOnDemand,
                baseURL: baseURL,
                accentIndex: 2
            )]
        case .liveDVR:
            return [streamEntry(
                id: "live-window",
                fixture: "live",
                title: LocalizedStringResource("Fixture live window", bundle: #bundle),
                detail: LocalizedStringResource("Jump to live or seek behind the edge", bundle: #bundle),
                kind: .live,
                baseURL: baseURL,
                accentIndex: 3
            )]
        case .offlineFirst:
            return shortEntries(
                fixtures: Array(FeedDemoFixtureCatalog.shortItems.prefix(20)),
                prefix: "offline",
                baseURL: baseURL
            )
        case .looping:
            return [streamEntry(
                id: "looping-short",
                fixture: "short-a",
                title: LocalizedStringResource("Focused-item loop", bundle: #bundle),
                detail: LocalizedStringResource("The engine restarts the same player lease", bundle: #bundle),
                kind: .videoOnDemand,
                baseURL: baseURL,
                accentIndex: 4
            )]
        case .stitched:
            let signature = HLSClipMediaSignature(
                container: .fragmentedMP4,
                codecs: ["avc1.640028", "mp4a.40.2"],
                tracks: [
                    .init(kind: .video, codec: "avc1.640028"),
                    .init(kind: .audio, codec: "mp4a.40.2", layout: "stereo"),
                ],
                videoRange: "SDR",
                segmentsAreIndependent: true
            )
            let clips = ["short-a", "short-b"].map { fixture in
                ProxyPlaybackClip(
                    id: fixture,
                    playlistURL: playlistURL(fixture: fixture, baseURL: baseURL),
                    mediaSignature: signature
                )
            }
            let id: FeedItemID = "stitched-a-b"
            return [FeedDemoEntry(
                id: id,
                title: LocalizedStringResource("Two-clip timeline", bundle: #bundle),
                detail: LocalizedStringResource("One standards-compliant playback surface", bundle: #bundle),
                item: FeedPlaybackItem(
                    id: id,
                    source: .compatibleClips(clips),
                    estimatedPreparationBytes: 1_024 * 1_024
                ),
                accentIndex: 5
            )]
        }
    }

    private static func shortEntries(
        fixtures: [FeedDemoFixtureCatalog.ShortItem],
        prefix: String,
        baseURL: URL
    ) -> [FeedDemoEntry] {
        fixtures.map { fixture in
            return streamEntry(
                id: FeedItemID(rawValue: "\(prefix)-\(fixture.index)"),
                fixture: "feed/\(fixture.fixtureID)",
                title: LocalizedStringResource(
                    "Moment \(fixture.index + 1): \(fixture.title)",
                    bundle: #bundle
                ),
                detail: LocalizedStringResource(
                    "\(fixture.segmentCount)-second local HLS fixture",
                    bundle: #bundle
                ),
                kind: .videoOnDemand,
                baseURL: baseURL,
                accentIndex: fixture.index,
                estimatedPreparationBytes: fixture.estimatedByteCount
            )
        }
    }

    private static func streamEntry(
        id: FeedItemID,
        fixture: String,
        title: LocalizedStringResource,
        detail: LocalizedStringResource,
        kind: FeedStreamKind,
        baseURL: URL,
        accentIndex: Int,
        estimatedPreparationBytes: Int? = nil
    ) -> FeedDemoEntry {
        FeedDemoEntry(
            id: id,
            title: title,
            detail: detail,
            item: FeedPlaybackItem(
                id: id,
                source: .stream(url: playlistURL(fixture: fixture, baseURL: baseURL), kind: kind),
                estimatedPreparationBytes: estimatedPreparationBytes
                    ?? (fixture == "long-form" ? 2_048 * 1_024 : 512 * 1_024)
            ),
            accentIndex: accentIndex
        )
    }

    private static func playlistURL(fixture: String, baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent(fixture, isDirectory: true)
            .appendingPathComponent("playlist.m3u8")
    }
}

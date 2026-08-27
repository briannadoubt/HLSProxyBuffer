import Foundation

public struct HLSParser: Sendable {
    public enum ParserError: Error, CustomStringConvertible {
        case missingHeader
        case malformedEXTINF(String)
        case missingURIAfterTag(String)
        case unresolvedURL(String)
        case malformedEXTMedia(String)
        case missingMediaAttribute(String)
        case unsupportedRenditionType(String)
        case missingKeyAttribute(String)
        case malformedKeyAttribute(String)
        case missingMapAttribute(String)
        case missingPartAttribute(String)
        case missingHintAttribute(String)
        case missingRenditionReportAttribute(String)
        case malformedByteRange(String)

        public var description: String {
            switch self {
            case .missingHeader:
                return "Playlist must start with #EXTM3U."
            case .malformedEXTINF(let value):
                return "Unable to parse EXTINF duration: \(value)."
            case .missingURIAfterTag(let tag):
                return "Expected URI following \(tag)."
            case .unresolvedURL(let value):
                return "Unable to resolve URL: \(value)."
            case .malformedEXTMedia(let value):
                return "Unable to parse EXT-X-MEDIA tag: \(value)."
            case .missingMediaAttribute(let attribute):
                return "EXT-X-MEDIA tag is missing required attribute \(attribute)."
            case .unsupportedRenditionType(let value):
                return "Unsupported EXT-X-MEDIA TYPE: \(value)."
            case .missingKeyAttribute(let attribute):
                return "EXT-X-KEY tag is missing required attribute \(attribute)."
            case .malformedKeyAttribute(let attribute):
                return "EXT-X-KEY attribute has unsupported value: \(attribute)."
            case .missingMapAttribute(let attribute):
                return "EXT-X-MAP tag is missing required attribute \(attribute)."
            case .missingPartAttribute(let attribute):
                return "EXT-X-PART tag is missing required attribute \(attribute)."
            case .missingHintAttribute(let attribute):
                return "EXT-X-PRELOAD-HINT tag is missing required attribute \(attribute)."
            case .missingRenditionReportAttribute(let attribute):
                return "EXT-X-RENDITION-REPORT tag is missing required attribute \(attribute)."
            case .malformedByteRange(let value):
                return "Invalid HLS byte range: \(value)."
            }
        }
    }

    private struct ByteRangeSpec {
        let length: Int
        let offset: Int?
    }

    private let logger: Logger

    public init(logger: Logger = DefaultLogger()) {
        self.logger = logger
    }

    public func parse(_ text: String, baseURL: URL?) throws -> HLSManifest {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard lines.first == "#EXTM3U" else {
            throw ParserError.missingHeader
        }

        var variants: [VariantPlaylist] = []
        var segments: [HLSSegment] = []
        var pendingVariantAttributes: VariantPlaylist.Attributes?
        var pendingDuration: TimeInterval?
        var pendingByteRange: ByteRangeSpec?
        var previousByteRangeEndByURL: [URL: Int] = [:]
        var previousPartByteRangeEndByURL: [URL: Int] = [:]
        var previousMapByteRangeEndByURL: [URL: Int] = [:]
        var currentSequence = 0
        var declaredMediaSequence = 0
        var targetDuration: TimeInterval?
        var isEndlist = false
        var renditions: [HLSManifest.Rendition] = []
        var currentEncryption: SegmentEncryption?
        var currentMap: MediaInitializationMap?
        var sessionKeys: [HLSKey] = []
        var pendingParts: [HLSPartialSegment] = []
        var partTargetDuration: TimeInterval?
        var serverControl: HLSServerControl?
        var preloadHints: [HLSPreloadHint] = []
        var renditionReports: [HLSRenditionReport] = []
        var skippedSegmentCount: Int?
        var protocolVersion: Int?
        var independentSegments = false
        var playlistType: String?
        var startTag: String?
        var discontinuitySequence: Int?
        var passthroughTags: [String] = []
        var pendingSegmentTags: [String] = []
        var variables: [String: String] = [:]

        for rawLine in lines {
            if rawLine.hasPrefix("#EXT-X-DEFINE:") {
                let value = String(rawLine.dropFirst("#EXT-X-DEFINE:".count))
                let attributes = attributeDictionary(from: value)
                if let name = attributes["NAME"], let variableValue = attributes["VALUE"] {
                    variables[name] = variableValue
                } else {
                    passthroughTags.append(rawLine)
                }
                continue
            }
            let line = substituteVariables(in: rawLine, variables: variables)
            guard !line.isEmpty else { continue }

            if line == "#EXTM3U" {
                continue
            } else if line.hasPrefix("#EXT-X-VERSION:") {
                protocolVersion = Int(line.dropFirst("#EXT-X-VERSION:".count))
            } else if line == "#EXT-X-ENDLIST" {
                isEndlist = true
            } else if line == "#EXT-X-INDEPENDENT-SEGMENTS" {
                independentSegments = true
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                playlistType = String(line.dropFirst("#EXT-X-PLAYLIST-TYPE:".count))
            } else if line.hasPrefix("#EXT-X-START:") {
                startTag = line
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
                discontinuitySequence = Int(line.dropFirst("#EXT-X-DISCONTINUITY-SEQUENCE:".count))
            } else if isSegmentMetadataTag(line) {
                pendingSegmentTags.append(line)
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.replacingOccurrences(of: "#EXTINF:", with: "")
                guard let duration = TimeInterval(value.split(separator: ",").first ?? "") else {
                    throw ParserError.malformedEXTINF(value)
                }
                pendingDuration = duration
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let value = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                pendingVariantAttributes = parseVariantAttributes(from: value)
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let value = line.replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:", with: "")
                currentSequence = Int(value) ?? currentSequence
                declaredMediaSequence = currentSequence
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                let value = line.replacingOccurrences(of: "#EXT-X-TARGETDURATION:", with: "")
                targetDuration = TimeInterval(value)
            } else if line.hasPrefix("#EXT-X-PART-INF:") {
                let value = line.replacingOccurrences(of: "#EXT-X-PART-INF:", with: "")
                let attributes = attributeDictionary(from: value)
                if let targetValue = attributes["PART-TARGET"], let parsed = TimeInterval(targetValue) {
                    partTargetDuration = parsed
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let value = line.replacingOccurrences(of: "#EXT-X-BYTERANGE:", with: "")
                pendingByteRange = try parseByteRangeSpec(from: value)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let value = String(line.dropFirst("#EXT-X-MEDIA:".count))
                let rendition = try parseRendition(from: value, baseURL: baseURL)
                renditions.append(rendition)
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let value = String(line.dropFirst("#EXT-X-KEY:".count))
                currentEncryption = try parseEncryptionTag(from: value, baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-SESSION-KEY:") {
                let value = String(line.dropFirst("#EXT-X-SESSION-KEY:".count))
                if let key = try parseSessionKey(from: value, baseURL: baseURL) {
                    sessionKeys.append(key)
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let value = String(line.dropFirst("#EXT-X-MAP:".count))
                currentMap = try parseInitializationMap(
                    from: value,
                    baseURL: baseURL,
                    previousByteRangeEnds: &previousMapByteRangeEndByURL
                )
            } else if line.hasPrefix("#EXT-X-PART:") {
                let value = String(line.dropFirst("#EXT-X-PART:".count))
                let part = try parsePartialSegment(
                    from: value,
                    sequence: currentSequence,
                    partIndex: pendingParts.count,
                    encryption: currentEncryption,
                    map: currentMap,
                    baseURL: baseURL,
                    previousByteRangeEnds: &previousPartByteRangeEndByURL
                )
                pendingParts.append(part)
            } else if line.hasPrefix("#EXT-X-PRELOAD-HINT:") {
                let value = String(line.dropFirst("#EXT-X-PRELOAD-HINT:".count))
                if let hint = try parsePreloadHint(
                    from: value,
                    sequence: currentSequence,
                    partIndex: pendingParts.count,
                    baseURL: baseURL
                ) {
                    preloadHints.append(hint)
                }
            } else if line.hasPrefix("#EXT-X-RENDITION-REPORT:") {
                let value = String(line.dropFirst("#EXT-X-RENDITION-REPORT:".count))
                if let report = try parseRenditionReport(from: value, baseURL: baseURL) {
                    renditionReports.append(report)
                }
            } else if line.hasPrefix("#EXT-X-SERVER-CONTROL:") {
                let value = String(line.dropFirst("#EXT-X-SERVER-CONTROL:".count))
                serverControl = parseServerControl(from: value)
            } else if line.hasPrefix("#EXT-X-SKIP:") {
                let value = String(line.dropFirst("#EXT-X-SKIP:".count))
                let attributes = attributeDictionary(from: value)
                if let skippedValue = attributes["SKIPPED-SEGMENTS"], let count = Int(skippedValue) {
                    skippedSegmentCount = count
                    if segments.isEmpty, count > 0 {
                        currentSequence += count
                    }
                }
            } else if line.hasPrefix("#") {
                passthroughTags.append(line)
            } else {
                if let attributes = pendingVariantAttributes {
                    let url = try resolveURL(line, baseURL: baseURL)
                    variants.append(VariantPlaylist(url: url, attributes: attributes))
                    pendingVariantAttributes = nil
                } else {
                    let url = try resolveURL(line, baseURL: baseURL)
                    let duration = pendingDuration ?? 0
                    let byteRange = try pendingByteRange.map {
                        try resolveByteRange(
                            $0,
                            for: url,
                            previousByteRangeEnds: &previousByteRangeEndByURL
                        )
                    }

                    segments.append(
                        HLSSegment(
                            url: url,
                            duration: duration,
                            sequence: currentSequence,
                            byteRange: byteRange,
                            encryption: currentEncryption,
                            initializationMap: currentMap,
                            parts: pendingParts,
                            metadataTags: pendingSegmentTags
                        )
                    )
                    pendingDuration = nil
                    pendingByteRange = nil
                    pendingParts.removeAll()
                    pendingSegmentTags.removeAll()
                    currentSequence += 1
                }
            }
        }

        if pendingVariantAttributes != nil {
            throw ParserError.missingURIAfterTag("#EXT-X-STREAM-INF")
        }
        if pendingDuration != nil || pendingByteRange != nil {
            throw ParserError.missingURIAfterTag(pendingDuration != nil ? "#EXTINF" : "#EXT-X-BYTERANGE")
        }

        let hasMediaBody = !segments.isEmpty || !pendingParts.isEmpty || targetDuration != nil || partTargetDuration != nil
        let mediaPlaylist = hasMediaBody ? MediaPlaylist(
            protocolVersion: protocolVersion,
            targetDuration: targetDuration,
            mediaSequence: declaredMediaSequence,
            segments: segments,
            isEndlist: isEndlist,
            sessionKeys: sessionKeys,
            partTargetDuration: partTargetDuration,
            serverControl: serverControl,
            preloadHints: preloadHints,
            renditionReports: renditionReports,
            skippedSegmentCount: skippedSegmentCount,
            independentSegments: independentSegments,
            playlistType: playlistType,
            startTag: startTag,
            discontinuitySequence: discontinuitySequence,
            passthroughTags: passthroughTags,
            trailingParts: pendingParts
        ) : nil

        let kind: HLSManifestKind = (variants.isEmpty && renditions.isEmpty) ? .media : .master

        logger.log(
            "Parsed manifest – kind: \(kind), variants: \(variants.count), renditions: \(renditions.count), segments: \(segments.count)",
            category: .parser
        )

        return HLSManifest(
            kind: kind,
            variants: variants,
            mediaPlaylist: mediaPlaylist,
            renditions: renditions,
            originalText: text,
            sessionKeys: sessionKeys,
            protocolVersion: protocolVersion,
            independentSegments: independentSegments,
            passthroughTags: passthroughTags + pendingSegmentTags
        )
    }

    private func resolveURL(_ string: String, baseURL: URL?) throws -> URL {
        do {
            return try URLUtilities.resolve(string, baseURL: baseURL)
        } catch {
            throw ParserError.unresolvedURL(string)
        }
    }

    private func parseVariantAttributes(from string: String) -> VariantPlaylist.Attributes {
        let attributes = attributeDictionary(from: string)
        var bandwidth: Int?
        var averageBandwidth: Int?
        var frameRate: Double?
        var resolution: VariantPlaylist.Resolution?
        var codecs: String?
        var audioGroupId: String?
        var subtitleGroupId: String?
        var closedCaptionGroupId: String?

        bandwidth = attributes["BANDWIDTH"].flatMap(Int.init)
        averageBandwidth = attributes["AVERAGE-BANDWIDTH"].flatMap(Int.init)
        frameRate = attributes["FRAME-RATE"].flatMap(Double.init)
        resolution = attributes["RESOLUTION"].flatMap(parseResolution(from:))
        codecs = attributes["CODECS"]
        audioGroupId = attributes["AUDIO"]
        subtitleGroupId = attributes["SUBTITLES"]
        closedCaptionGroupId = attributes["CLOSED-CAPTIONS"]
        let knownKeys: Set<String> = [
            "BANDWIDTH", "AVERAGE-BANDWIDTH", "FRAME-RATE", "RESOLUTION", "CODECS",
            "AUDIO", "SUBTITLES", "CLOSED-CAPTIONS"
        ]
        let additionalAttributes = attributes.filter { !knownKeys.contains($0.key) }

        return VariantPlaylist.Attributes(
            bandwidth: bandwidth,
            averageBandwidth: averageBandwidth,
            frameRate: frameRate,
            resolution: resolution,
            codecs: codecs,
            audioGroupId: audioGroupId,
            subtitleGroupId: subtitleGroupId,
            closedCaptionGroupId: closedCaptionGroupId,
            additionalAttributes: additionalAttributes
        )
    }

    private func parseResolution(from string: String) -> VariantPlaylist.Resolution? {
        let components = string.split(whereSeparator: { $0 == "x" || $0 == "X" })
        guard components.count == 2,
              let width = Int(components[0]),
              let height = Int(components[1]) else {
            return nil
        }
        return VariantPlaylist.Resolution(width: width, height: height)
    }

    private func parseByteRangeSpec(from string: String) throws -> ByteRangeSpec {
        let components = string.split(separator: "@", omittingEmptySubsequences: false)
        guard components.count <= 2,
              let length = Int(components.first ?? ""),
              length > 0 else {
            throw ParserError.malformedByteRange(string)
        }
        let offset: Int?
        if components.count == 2 {
            guard let parsedOffset = Int(components[1]), parsedOffset >= 0 else {
                throw ParserError.malformedByteRange(string)
            }
            offset = parsedOffset
        } else {
            offset = nil
        }
        return ByteRangeSpec(length: length, offset: offset)
    }

    private func resolveByteRange(
        _ spec: ByteRangeSpec,
        for url: URL,
        previousByteRangeEnds: inout [URL: Int]
    ) throws -> ClosedRange<Int> {
        let start: Int
        if let offset = spec.offset {
            start = offset
        } else if let previousEnd = previousByteRangeEnds[url], previousEnd < Int.max {
            start = previousEnd + 1
        } else {
            throw ParserError.malformedByteRange("\(spec.length) without a previous range for \(url.absoluteString)")
        }
        let (distance, overflow) = spec.length.subtractingReportingOverflow(1)
        let (end, additionOverflow) = start.addingReportingOverflow(distance)
        guard !overflow, !additionOverflow, end >= start else {
            throw ParserError.malformedByteRange("\(spec.length)@\(start)")
        }
        previousByteRangeEnds[url] = end
        return start...end
    }

    private func parsePartialSegment(
        from string: String,
        sequence: Int,
        partIndex: Int,
        encryption: SegmentEncryption?,
        map: MediaInitializationMap?,
        baseURL: URL?,
        previousByteRangeEnds: inout [URL: Int]
    ) throws -> HLSPartialSegment {
        let attributes = attributeDictionary(from: string)
        guard let durationValue = attributes["DURATION"], let duration = TimeInterval(durationValue) else {
            throw ParserError.missingPartAttribute("DURATION")
        }
        guard let uriValue = attributes["URI"], !uriValue.isEmpty else {
            throw ParserError.missingPartAttribute("URI")
        }
        let url = try resolveURL(uriValue, baseURL: baseURL)
        let range: ClosedRange<Int>?
        if let value = attributes["BYTERANGE"] {
            range = try resolveByteRange(
                parseByteRangeSpec(from: value),
                for: url,
                previousByteRangeEnds: &previousByteRangeEnds
            )
        } else {
            range = nil
        }
        let isIndependent = parseBoolean(attributes["INDEPENDENT"]) ?? false
        let isGap = parseBoolean(attributes["GAP"]) ?? false
        return HLSPartialSegment(
            parentSequence: sequence,
            partIndex: partIndex,
            duration: duration,
            url: url,
            byteRange: range,
            isIndependent: isIndependent,
            isGap: isGap,
            encryption: encryption,
            initializationMap: map
        )
    }

    private func parsePreloadHint(
        from string: String,
        sequence: Int,
        partIndex: Int,
        baseURL: URL?
    ) throws -> HLSPreloadHint? {
        let attributes = attributeDictionary(from: string)
        guard let typeValue = attributes["TYPE"], !typeValue.isEmpty else {
            throw ParserError.missingHintAttribute("TYPE")
        }
        guard let type = HLSPreloadHint.HintType(rawValue: typeValue.uppercased()) else {
            return nil
        }
        guard let uriValue = attributes["URI"], !uriValue.isEmpty else {
            throw ParserError.missingHintAttribute("URI")
        }
        let url = try resolveURL(uriValue, baseURL: baseURL)
        let start = attributes["BYTERANGE-START"].flatMap(Int.init)
        let length = attributes["BYTERANGE-LENGTH"].flatMap(Int.init)
        let hintPartIndex = type == .part ? partIndex : nil
        return HLSPreloadHint(
            type: type,
            uri: url,
            byteRangeStart: start,
            byteRangeLength: length,
            sequence: sequence,
            partIndex: hintPartIndex
        )
    }

    private func parseRenditionReport(from string: String, baseURL: URL?) throws -> HLSRenditionReport? {
        let attributes = attributeDictionary(from: string)
        guard let uriValue = attributes["URI"], !uriValue.isEmpty else {
            throw ParserError.missingRenditionReportAttribute("URI")
        }
        let uri = try resolveURL(uriValue, baseURL: baseURL)
        let lastMSN = attributes["LAST-MSN"].flatMap(Int.init)
        let lastPart = attributes["LAST-PART"].flatMap(Int.init)
        let bandwidth = attributes["AVERAGE-BANDWIDTH"].flatMap(Int.init)
        return HLSRenditionReport(
            uri: uri,
            lastMediaSequence: lastMSN,
            lastPartIndex: lastPart,
            averageBandwidth: bandwidth
        )
    }

    private func parseServerControl(from string: String) -> HLSServerControl? {
        let attributes = attributeDictionary(from: string)
        let canSkipUntil = attributes["CAN-SKIP-UNTIL"].flatMap(TimeInterval.init)
        let canBlock = parseBoolean(attributes["CAN-BLOCK-RELOAD"]) ?? false
        let canPrefetch = parseBoolean(attributes["CAN-PREFETCH"]) ?? false
        let canSkipDateRanges = parseBoolean(attributes["CAN-SKIP-DATERANGES"]) ?? false
        let holdBack = attributes["HOLD-BACK"].flatMap(TimeInterval.init)
        let partHoldBack = attributes["PART-HOLD-BACK"].flatMap(TimeInterval.init)
        let partTarget = attributes["PART-TARGET"].flatMap(TimeInterval.init)
        if canSkipUntil == nil && !canBlock && !canPrefetch && !canSkipDateRanges && holdBack == nil && partHoldBack == nil && partTarget == nil {
            return nil
        }
        return HLSServerControl(
            canSkipUntil: canSkipUntil,
            canBlockReload: canBlock,
            canSkipDateRanges: canSkipDateRanges,
            canPrefetch: canPrefetch,
            holdBack: holdBack,
            partHoldBack: partHoldBack,
            partTarget: partTarget
        )
    }

    private func splitAttributes(_ string: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var isInQuotes = false

        for character in string {
            if character == "\"" {
                isInQuotes.toggle()
                current.append(character)
                continue
            }

            if character == "," && !isInQuotes {
                parts.append(current)
                current.removeAll()
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            parts.append(current)
        }

        return parts
    }

    private func attributeDictionary(from string: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in splitAttributes(string) {
            let components = pair.split(separator: "=", maxSplits: 1)
            guard components.count == 2 else { continue }
            let key = components[0].trimmingCharacters(in: .whitespaces)
            var value = components[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key.uppercased()] = value
        }
        return result
    }

    private func renditionKind(from value: String) -> HLSManifest.Rendition.Kind? {
        switch value.uppercased() {
        case "AUDIO":
            return .audio
        case "SUBTITLES":
            return .subtitles
        case "CLOSED-CAPTIONS":
            return .closedCaptions
        default:
            return nil
        }
    }

    private func parseRendition(from string: String, baseURL: URL?) throws -> HLSManifest.Rendition {
        let attributes = attributeDictionary(from: string)

        guard let typeValue = attributes["TYPE"] else {
            throw ParserError.missingMediaAttribute("TYPE")
        }
        guard let kind = renditionKind(from: typeValue) else {
            throw ParserError.unsupportedRenditionType(typeValue)
        }
        guard let groupId = attributes["GROUP-ID"], !groupId.isEmpty else {
            throw ParserError.missingMediaAttribute("GROUP-ID")
        }
        guard let name = attributes["NAME"], !name.isEmpty else {
            throw ParserError.missingMediaAttribute("NAME")
        }

        var resolvedURI: URL?
        let instreamId = attributes["INSTREAM-ID"]

        if let uriValue = attributes["URI"], !uriValue.isEmpty {
            resolvedURI = try resolveURL(uriValue, baseURL: baseURL)
        }

        if kind.requiresURI {
            guard resolvedURI != nil else {
                throw ParserError.missingMediaAttribute("URI")
            }
        }

        if kind.requiresInstreamId {
            guard let instreamId, !instreamId.isEmpty else {
                throw ParserError.missingMediaAttribute("INSTREAM-ID")
            }
        }

        let language = attributes["LANGUAGE"]
        let isDefault = parseBoolean(attributes["DEFAULT"]) ?? false
        let isAutoSelect = parseBoolean(attributes["AUTOSELECT"]) ?? false
        let isForced = parseBoolean(attributes["FORCED"]) ?? false
        let characteristics: [String]
        if let value = attributes["CHARACTERISTICS"], !value.isEmpty {
            characteristics = value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        } else {
            characteristics = []
        }
        let knownKeys: Set<String> = [
            "TYPE", "GROUP-ID", "NAME", "LANGUAGE", "DEFAULT", "AUTOSELECT", "FORCED",
            "CHARACTERISTICS", "URI", "INSTREAM-ID"
        ]
        let additionalAttributes = attributes.filter { !knownKeys.contains($0.key) }

        return HLSManifest.Rendition(
            type: kind,
            groupId: groupId,
            name: name,
            language: language,
            isDefault: isDefault,
            isAutoSelect: isAutoSelect,
            isForced: isForced,
            characteristics: characteristics,
            uri: resolvedURI,
            instreamId: instreamId,
            additionalAttributes: additionalAttributes
        )
    }

    private func parseBoolean(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.uppercased() {
        case "YES":
            return true
        case "NO":
            return false
        default:
            return nil
        }
    }

    private func parseEncryptionTag(from string: String, baseURL: URL?) throws -> SegmentEncryption? {
        let attributes = attributeDictionary(from: string)
        guard let methodValue = attributes["METHOD"] else {
            throw ParserError.missingKeyAttribute("METHOD")
        }
        guard let method = keyMethod(from: methodValue) else {
            throw ParserError.malformedKeyAttribute(methodValue)
        }

        let uri = try resolveKeyURI(attributes["URI"], method: method, baseURL: baseURL)
        let keyFormat = attributes["KEYFORMAT"]
        let versions = parseKeyFormatVersions(attributes["KEYFORMATVERSIONS"])
        let key = HLSKey(
            method: method,
            uri: uri,
            keyFormat: keyFormat,
            keyFormatVersions: versions,
            isSessionKey: false
        )
        let iv = attributes["IV"]
        return SegmentEncryption(key: key, initializationVector: iv)
    }

    private func parseSessionKey(from string: String, baseURL: URL?) throws -> HLSKey? {
        let attributes = attributeDictionary(from: string)
        guard let methodValue = attributes["METHOD"] else {
            throw ParserError.missingKeyAttribute("METHOD")
        }
        guard let method = keyMethod(from: methodValue) else {
            throw ParserError.malformedKeyAttribute(methodValue)
        }
        let uri = try resolveKeyURI(attributes["URI"], method: method, baseURL: baseURL)
        let keyFormat = attributes["KEYFORMAT"]
        let versions = parseKeyFormatVersions(attributes["KEYFORMATVERSIONS"])
        return HLSKey(
            method: method,
            uri: uri,
            keyFormat: keyFormat,
            keyFormatVersions: versions,
            isSessionKey: true
        )
    }

    private func keyMethod(from value: String) -> HLSKey.Method? {
        switch value.uppercased() {
        case HLSKey.Method.none.rawValue:
            return HLSKey.Method.none
        case HLSKey.Method.aes128.rawValue:
            return HLSKey.Method.aes128
        case HLSKey.Method.sampleAES.rawValue:
            return HLSKey.Method.sampleAES
        case HLSKey.Method.sampleAESCTR.rawValue:
            return HLSKey.Method.sampleAESCTR
        default:
            return nil
        }
    }

    private func resolveKeyURI(_ value: String?, method: HLSKey.Method, baseURL: URL?) throws -> URL? {
        guard method != .none else { return nil }
        guard let value, !value.isEmpty else {
            throw ParserError.missingKeyAttribute("URI")
        }
        return try resolveURL(value, baseURL: baseURL)
    }

    private func parseKeyFormatVersions(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: "/").map { String($0) }
    }

    private func parseInitializationMap(
        from string: String,
        baseURL: URL?,
        previousByteRangeEnds: inout [URL: Int]
    ) throws -> MediaInitializationMap {
        let attributes = attributeDictionary(from: string)
        guard let uriValue = attributes["URI"], !uriValue.isEmpty else {
            throw ParserError.missingMapAttribute("URI")
        }
        let resolvedURI = try resolveURL(uriValue, baseURL: baseURL)
        let range: ClosedRange<Int>?
        if let value = attributes["BYTERANGE"] {
            range = try resolveByteRange(
                parseByteRangeSpec(from: value),
                for: resolvedURI,
                previousByteRangeEnds: &previousByteRangeEnds
            )
        } else {
            range = nil
        }
        return MediaInitializationMap(uri: resolvedURI, byteRange: range)
    }

    private func isSegmentMetadataTag(_ line: String) -> Bool {
        line == "#EXT-X-DISCONTINUITY"
            || line == "#EXT-X-GAP"
            || line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
            || line.hasPrefix("#EXT-X-DATERANGE:")
            || line.hasPrefix("#EXT-X-BITRATE:")
            || line.hasPrefix("#EXT-X-CUE-OUT")
            || line == "#EXT-X-CUE-IN"
            || line.hasPrefix("#EXT-OATCLS-SCTE35:")
            || line.hasPrefix("#EXT-X-SCTE35:")
            || line.hasPrefix("#EXT-X-ASSET:")
            || line.hasPrefix("#EXT-X-PLACEMENT-OPPORTUNITY:")
    }

    private func substituteVariables(in value: String, variables: [String: String]) -> String {
        variables.reduce(value) { result, pair in
            result.replacingOccurrences(of: "{$\(pair.key)}", with: pair.value)
        }
    }
}

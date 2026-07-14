import Foundation

struct SeparationPreset: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let modelFilename: String
    let summary: String
    let expectedStems: [String]
    var usageCount: Int? = nil

    var normalizedUsageCount: Int {
        max(0, usageCount ?? 0)
    }
}

struct SeparatorModel: Identifiable, Hashable, Codable {
    var id: String { filename }

    let filename: String
    let name: String
    let type: String
    let stems: [String]
    let sdr: [String: Double?]
    let isDownloaded: Bool

    var pickerTitle: String {
        name.isEmpty ? filename : name
    }
}

struct StemFile: Identifiable, Hashable, Codable {
    var id: String { path }

    let stem: String
    let path: String
    let sizeBytes: Int
    /// Process settings for this separation (from backend or sidecar).
    var runInfo: StemRunInfo?

    static func cleanModelName(_ raw: String) -> String {
        var parts = raw.split(separator: " ").map(String.init)
        let rawWordsToStrip: Set<String> = [
            "bs", "leap", "xe", "voc", "inst", "roformer", "sw", "deux", "becruily", "other", "vocals",
            "hyperace", "hyperacev2", "v2", "drumsep", "5stems", "mdx23c", "jarredou", "mega", "53stem",
            "lead-vocal", "back-vocal", "drums", "sitar", "piano", "mvsep", "melodyshield", "karaoke", "anvuew",
            "gonza", "mel", "band", "bve"
        ]
        while !parts.isEmpty {
            let lower = parts[0].lowercased()
            let subparts = lower.split { $0 == "-" || $0 == "_" }.map(String.init)
            let isRaw = subparts.allSatisfy { sub in
                rawWordsToStrip.contains(sub) || sub.hasSuffix(".ckpt") || sub.hasSuffix(".yaml")
            } || rawWordsToStrip.contains(lower)
            
            if isRaw {
                parts.removeFirst()
            } else {
                break
            }
        }
        return parts.joined(separator: " ")
    }

    static func formatDisplay(stem: String, suffix: String) -> String {
        let clean = cleanModelName(suffix)
        let parts = clean.split(separator: " ").map(String.init)
        
        let presetKeywords = ["heavy", "max", "custom", "fast", "extreme", "default"]
        var presetIndex: Int? = nil
        
        for (index, part) in parts.enumerated() {
            if presetKeywords.contains(part.lowercased()) {
                presetIndex = index
                break
            }
        }
        
        if let idx = presetIndex {
            let modelPart = parts[..<idx].joined(separator: " ")
            let presetPart = parts[idx...].joined(separator: " ").capitalized
            
            var result = stem.capitalized
            if !modelPart.isEmpty {
                result += " • \(modelPart)"
            }
            result += " • \(presetPart)"
            return result
        } else {
            var result = stem.capitalized
            if !clean.isEmpty {
                result += " • \(clean)"
            }
            return result
        }
    }

    var rawModelName: String {
        if let runInfo, let modelFile = runInfo.modelFilename {
            return URL(fileURLWithPath: modelFile).deletingPathExtension().lastPathComponent
        }
        
        let fileStem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let role = Self.roleLabel(fromFileStem: fileStem) ?? stem
        var suffix = ""
        let candidates = [
            "_(\(role))",
            "_(\(role.replacingOccurrences(of: "_", with: " ")))",
        ]
        for candidate in candidates {
            if let matchRange = fileStem.range(of: candidate) {
                suffix = String(fileStem[matchRange.upperBound...])
                break
            }
        }
        if suffix.hasPrefix("_") {
            suffix.removeFirst()
        }
        
        let parts = suffix.split(separator: "_").map(String.init)
        let rawWordsToStrip: Set<String> = [
            "bs", "leap", "xe", "voc", "inst", "roformer", "sw", "deux", "becruily"
        ]
        var rawParts: [String] = []
        for part in parts {
            let lower = part.lowercased()
            if rawWordsToStrip.contains(lower) || lower.hasSuffix(".ckpt") || lower.hasSuffix(".yaml") {
                rawParts.append(part)
            } else {
                break
            }
        }
        if !rawParts.isEmpty {
            return rawParts.joined(separator: "_")
        }
        return ""
    }

    var displayName: String {
        if let runInfo, let model = runInfo.modelDisplayName, !model.isEmpty {
            var result = (runInfo.stem ?? stem).capitalized
            result += " • \(model)"
            if let preset = runInfo.processPresetTitle {
                let cleanPreset = preset.lowercased().hasPrefix("heavy") ? "Heavy" : preset.capitalized
                result += " • \(cleanPreset)"
            }
            return result
        }

        let fileStem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let role = Self.roleLabel(fromFileStem: fileStem) ?? stem
        let prettyRole = role.capitalized
        
        var suffix = ""
        let candidates = [
            "_(\(role))",
            "_(\(role.replacingOccurrences(of: "_", with: " ")))",
        ]
        for candidate in candidates {
            if let matchRange = fileStem.range(of: candidate) {
                suffix = String(fileStem[matchRange.upperBound...])
                break
            }
        }
        if suffix.isEmpty {
            if let range = fileStem.range(of: "_\(role)", options: .backwards) {
                suffix = String(fileStem[range.upperBound...])
            }
        }
        if suffix.isEmpty {
            let baseCandidates = [
                "_(" + stem + ")",
                "_(" + stem.replacingOccurrences(of: "_", with: " ") + ")",
            ]
            for candidate in baseCandidates {
                if let matchRange = fileStem.range(of: candidate) {
                    suffix = String(fileStem[matchRange.upperBound...])
                    break
                }
            }
        }
        
        if suffix.hasPrefix("_") {
            suffix.removeFirst()
        }
        let cleanedSuffix = suffix.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !cleanedSuffix.isEmpty {
            return Self.formatDisplay(stem: prettyRole, suffix: cleanedSuffix)
        }
        return prettyRole
    }

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Load sibling `.aura-run.json` (or legacy `.kirtan-run.json`) written next to the stem audio.
    mutating func loadRunInfoFromSidecar() {
        if runInfo != nil { return }
        let url = URL(fileURLWithPath: path)
        
        let sidecarBase = url.deletingPathExtension()
        let sidecarAltBase = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            
        let candidates = [
            sidecarAltBase.appendingPathExtension("aura-run.json"),
            sidecarBase.appendingPathExtension("aura-run.json"),
            sidecarAltBase.appendingPathExtension("kirtan-run.json"),
            sidecarBase.appendingPathExtension("kirtan-run.json")
        ]
        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let data = try? Data(contentsOf: candidate),
                  let info = try? JSONDecoder().decode(StemRunInfo.self, from: data)
            else { continue }
            runInfo = info
            return
        }
    }

    private static func roleLabel(fromFileStem fileStem: String) -> String? {
        guard let open = fileStem.range(of: "_("),
              let close = fileStem.range(of: ")", range: open.upperBound..<fileStem.endIndex)
        else { return nil }
        let role = String(fileStem[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        return role.isEmpty ? nil : role
    }
}

/// Per-stem process snapshot for experiment comparison (Results → Info).
struct StemRunInfo: Codable, Hashable {
    var formatVersion: Int?
    var writtenAt: Double?
    var stem: String?
    var path: String?
    var modelFilename: String?
    var modelDisplayName: String?
    var modelPreset: String?
    var processPresetID: String?
    var processPresetTitle: String?
    var outputFormat: String?
    var chunkDuration: Double?
    var chunkLabel: String?
    var segmentSize: Int?
    var overlap: Int?
    var batchSize: Int?
    var overrideModelSegment: Bool?
    var speedMode: String?
    var performanceFlags: [String: Bool]?
    var modelHot: Bool?
    var sourceDurationSeconds: Double?
    var elapsedSeconds: Double?
    var realtimeFactor: Double?
    var estimatedChunks: Int?
    var experimentalFlagsEnabled: Int?

    var infoRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let model = modelDisplayName ?? modelFilename {
            rows.append(("model", model))
        }
        if let checkpoint = modelFilename, modelDisplayName != nil {
            rows.append(("checkpoint", checkpoint))
        }
        if let preset = modelPreset {
            rows.append(("model preset", preset))
        }
        if let process = processPresetTitle ?? processPresetID {
            rows.append(("process", process))
        }
        if let chunk = chunkLabel {
            rows.append(("chunk", chunk))
        } else if let chunkDuration {
            rows.append(("chunk", chunkDuration > 0 ? "\(Int(chunkDuration))s" : "off"))
        }
        if let estimatedChunks {
            rows.append(("est. chunks", "\(estimatedChunks)"))
        }
        if let segmentSize {
            rows.append(("segment", "\(segmentSize)"))
        }
        if let overlap {
            rows.append(("overlap", "\(overlap)"))
        }
        if let batchSize {
            rows.append(("batch", "\(batchSize)"))
        }
        if let speedMode {
            rows.append(("speed", speedMode))
        }
        if let overrideModelSegment {
            rows.append(("override segment", overrideModelSegment ? "on" : "off"))
        }
        if let format = outputFormat {
            rows.append(("format", format))
        }
        if let hot = modelHot {
            rows.append(("model cache", hot ? "hot (reused)" : "cold (loaded)"))
        }
        if let elapsed = elapsedSeconds {
            rows.append(("wall time", FileHelpers.formattedDurationWithRawSeconds(elapsed)))
        }
        if let rtf = realtimeFactor {
            rows.append(("realtime factor", String(format: "%.2f×", rtf)))
        }
        if let sourceDurationSeconds {
            rows.append(("source length", FileHelpers.formattedDuration(sourceDurationSeconds)))
        }
        if let flags = experimentalFlagsEnabled {
            rows.append(("exp. flags", "\(flags) on"))
        } else if let performanceFlags {
            let on = performanceFlags.values.filter { $0 }.count
            rows.append(("exp. flags", "\(on) on"))
        }
        return rows
    }

    /// Build from the batch SeparationSummary when a run just finished.
    static func from(summary: SeparationSummary, stem: String, path: String) -> StemRunInfo {
        let stats = summary.postRunStats
        return StemRunInfo(
            formatVersion: 1,
            writtenAt: summary.completedAt,
            stem: stem,
            path: path,
            modelFilename: summary.model,
            modelDisplayName: nil,
            modelPreset: summary.preset,
            processPresetID: summary.processPresetID ?? stats?.processPresetID,
            processPresetTitle: summary.processPresetTitle ?? stats?.processPresetTitle,
            outputFormat: stats?.outputFormat ?? summary.settings.map { _ in "WAV" },
            chunkDuration: stats?.chunkDurationSeconds ?? summary.settings?.chunkDuration,
            chunkLabel: stats?.chunkLabel,
            segmentSize: stats?.segmentSize ?? summary.settings?.mdxcSegmentSize,
            overlap: stats?.overlap ?? summary.settings?.mdxcOverlap,
            batchSize: stats?.batchSize ?? summary.settings?.mdxcBatchSize,
            overrideModelSegment: stats?.overrideModelSegment ?? summary.settings?.mdxcOverrideModelSegmentSize,
            speedMode: stats?.speedMode ?? summary.settings?.speedMode,
            performanceFlags: nil,
            modelHot: stats?.modelHot ?? summary.modelHot,
            sourceDurationSeconds: stats?.sourceDurationSeconds,
            elapsedSeconds: stats?.elapsedSeconds ?? summary.elapsedSeconds,
            realtimeFactor: stats?.realtimeFactor,
            estimatedChunks: stats?.estimatedChunks,
            experimentalFlagsEnabled: stats?.experimentalFlagsEnabled
        )
    }
}

struct SeparationSettings: Equatable, Codable {
    static let defaultMDXCSegmentSize = 256

    var presetID = "kirtan_pro"
    var modelOverride: String?
    var outputFormat = "WAV"
    var speedMode = "latency_safe_v3"
    var chunkDuration: Double = 30
    var mdxcSegmentSize: Int = defaultMDXCSegmentSize
    var mdxcOverlap: Int = 8
    var mdxcBatchSize: Int = 1
    var mdxcOverrideModelSegmentSize = false
    var saveConvertedSafetensors = true
    var performanceFlags: [String: Bool] = [:]

    var chunkDurationForBackend: Double? {
        chunkDuration > 0 ? chunkDuration : nil
    }

    var effectiveMDXCOverrideModelSegmentSize: Bool {
        mdxcOverrideModelSegmentSize || mdxcSegmentSize != Self.defaultMDXCSegmentSize
    }
}

struct SeparationSummary: Codable {
    let model: String
    let preset: String?
    let processPresetID: String?
    let processPresetTitle: String?
    let startedAt: Double?
    let completedAt: Double?
    let elapsedSeconds: Double
    let files: [StemFile]
    let metrics: [String: Double]?
    let modelHot: Bool?
    let modelCache: ModelCache?
    let settings: RunSettings?
    let postRunStats: PostRunStats?
}

/// Backend-built compact stats for the Post Run Stats panel.
struct PostRunStats: Codable, Equatable {
    let modelHot: Bool?
    let processPresetID: String?
    let processPresetTitle: String?
    let modelFilename: String?
    let modelPreset: String?
    let sourceDurationSeconds: Double?
    let elapsedSeconds: Double?
    let realtimeFactor: Double?
    let chunkDurationSeconds: Double?
    let chunkLabel: String?
    let estimatedChunks: Int?
    let segmentSize: Int?
    let overlap: Int?
    let batchSize: Int?
    let batchExplicit: Bool?
    let overrideModelSegment: Bool?
    let speedMode: String?
    let outputFormat: String?
    let experimentalFlagsEnabled: Int?
    let experimentalFlags: [String]?
}

struct LastRunReport {
    let summary: SeparationSummary

    var overviewRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("model", summary.model),
            ("preset", summary.preset ?? "default"),
        ]
        if let processTitle = summary.processPresetTitle ?? summary.postRunStats?.processPresetTitle,
           !processTitle.isEmpty {
            rows.append(("process", processTitle))
        }
        if let startedAt = summary.startedAt {
            rows.append(("started", Self.formattedRunDate(startedAt)))
        }
        if let completedAt = summary.completedAt {
            rows.append(("completed", Self.formattedRunDate(completedAt)))
        }
        rows.append(("elapsed", FileHelpers.formattedDurationWithRawSeconds(summary.elapsedSeconds)))
        rows.append(("outputs", "\(summary.files.count) \(summary.files.count == 1 ? "file" : "files")"))
        rows.append(("output size", formattedByteTotal(summary.files.reduce(0) { $0 + $1.sizeBytes })))
        return rows
    }

    /// High-signal rows for A/B experiments (chunk, batch, warm cache, RTF).
    var postRunStatRows: [(String, String)] {
        if let stats = summary.postRunStats {
            var rows: [(String, String)] = []
            if let hot = stats.modelHot {
                rows.append(("model cache", hot ? "hot (reused)" : "cold (loaded)"))
            }
            if let duration = stats.sourceDurationSeconds {
                rows.append(("source length", FileHelpers.formattedDuration(duration)))
            }
            if let elapsed = stats.elapsedSeconds {
                rows.append(("wall time", FileHelpers.formattedDurationWithRawSeconds(elapsed)))
            }
            if let rtf = stats.realtimeFactor {
                rows.append(("realtime factor", String(format: "%.2f×", rtf)))
            }
            rows.append(("chunk", stats.chunkLabel ?? (stats.chunkDurationSeconds.map { "\(Int($0))s" } ?? "off")))
            if let chunks = stats.estimatedChunks {
                rows.append(("est. chunks", "\(chunks)"))
            }
            if let segment = stats.segmentSize {
                rows.append(("segment", "\(segment)"))
            }
            if let overlap = stats.overlap {
                rows.append(("overlap", "\(overlap)"))
            }
            if let batch = stats.batchSize {
                let tag = stats.batchExplicit == true ? "" : " (heuristic)"
                rows.append(("batch", "\(batch)\(tag)"))
            }
            if let speed = stats.speedMode {
                rows.append(("speed mode", speed))
            }
            if let flags = stats.experimentalFlagsEnabled {
                rows.append(("exp. flags", "\(flags) on"))
            }
            if let process = stats.processPresetTitle, !process.isEmpty {
                rows.append(("process preset", process))
            }
            return rows
        }

        // Fallback when older backends omit postRunStats.
        var rows: [(String, String)] = []
        if let hot = summary.modelHot {
            rows.append(("model cache", hot ? "hot (reused)" : "cold (loaded)"))
        }
        rows.append(contentsOf: settingRows)
        return rows
    }

    var settingRows: [(String, String)] {
        guard let settings = summary.settings else { return [] }
        return [
            ("chunk", settings.chunkDuration.map { FileHelpers.formattedDuration($0) } ?? "off"),
            ("segment", settings.mdxcSegmentSize.map(String.init) ?? "default"),
            ("overlap", settings.mdxcOverlap.map(String.init) ?? "default"),
            ("batch", settings.mdxcBatchSize.map(String.init) ?? "default"),
            ("override", settings.mdxcOverrideModelSegmentSize == true ? "on" : "off"),
            ("speed", settings.speedMode ?? "default"),
        ]
    }

    var metricRows: [(String, String)] {
        let order = ["decode_s", "preprocess_s", "inference_s", "postprocess_s", "write_s", "cleanup_s", "total_s"]
        guard let metrics = summary.metrics else { return [] }
        return order.compactMap { key -> (String, String)? in
            guard let value = metrics[key] else { return nil }
            return (key.replacingOccurrences(of: "_s", with: ""), String(format: "%.3fs", value))
        }
    }

    var fileRows: [(String, String)] {
        summary.files.map { file in
            (file.displayName, "\(file.fileName) - \(formattedByteTotal(file.sizeBytes))")
        }
    }

    /// One-line status bar after finish.
    var statusLineSummary: String {
        let elapsed = FileHelpers.formattedDurationWithRawSeconds(summary.elapsedSeconds)
        let hot: String
        if let h = summary.postRunStats?.modelHot ?? summary.modelHot {
            hot = h ? "hot" : "cold"
        } else {
            hot = "—"
        }
        let chunk = summary.postRunStats?.chunkLabel
            ?? summary.settings?.chunkDuration.map { "\(Int($0))s" }
            ?? "off"
        let batch = summary.postRunStats?.batchSize.map(String.init)
            ?? summary.settings?.mdxcBatchSize.map(String.init)
            ?? "?"
        let chunks = summary.postRunStats?.estimatedChunks.map { "~\($0) chunks" } ?? ""
        let rtf = summary.postRunStats?.realtimeFactor.map { String(format: "%.2f×RT" , $0) } ?? ""
        return [elapsed, "cache \(hot)", "chunk \(chunk)", "batch \(batch)", chunks, rtf]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    static func formattedRunDate(_ timestamp: Double, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private func formattedByteTotal(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) \(bytes == 1 ? "byte" : "bytes")"
        }
        return FileHelpers.formattedBytes(bytes)
    }
}

struct RunSettings: Codable {
    let chunkDuration: Double?
    let mdxcSegmentSize: Int?
    let mdxcOverlap: Int?
    let mdxcBatchSize: Int?
    let mdxcOverrideModelSegmentSize: Bool?
    let speedMode: String?
    let processPresetTitle: String?
}

struct ModelPresetMenuState: Equatable {
    let isLocal: Bool
    let usageCount: Int
    static let empty = ModelPresetMenuState(isLocal: false, usageCount: 0)

    init(preset: SeparationPreset, models: [SeparatorModel], modelCache: ModelCache?) {
        let matchingModel = models.first { $0.filename == preset.modelFilename }
        let matchingGroup = modelCache?.groups?.first { group in
            Self.group(group, matches: preset.modelFilename)
        }

        isLocal = (matchingModel?.isDownloaded ?? false) || Self.isLocalCacheGroup(matchingGroup)
        usageCount = max(0, preset.usageCount ?? 0, matchingGroup?.usageCount ?? 0)
    }

    private init(isLocal: Bool, usageCount: Int) {
        self.isLocal = isLocal
        self.usageCount = max(0, usageCount)
    }

    var usageLabel: String? {
        usageCount > 0 ? "x\(usageCount)" : nil
    }

    var helpText: String {
        let localText = isLocal ? "Cached locally" : "Downloads on first use"
        guard usageCount > 0 else { return localText }
        return "\(localText) - used \(usageCount) \(usageCount == 1 ? "time" : "times")"
    }

    private static func isLocalCacheGroup(_ group: ModelCacheGroup?) -> Bool {
        guard let group else { return false }
        if group.converted || group.hasSource { return true }
        return group.localState == "installed" || group.localState == "downloaded"
    }

    private static func group(_ group: ModelCacheGroup, matches modelFilename: String) -> Bool {
        if group.technicalName == modelFilename { return true }
        let stem = URL(fileURLWithPath: modelFilename).deletingPathExtension().lastPathComponent
        if group.id == stem { return true }
        if group.convertedPath?.contains(stem) == true { return true }
        if group.sourcePath?.contains(modelFilename) == true { return true }
        return group.files.contains { $0.filename == modelFilename || $0.filename.hasPrefix("\(stem).") }
    }
}

struct RenderEstimate: Codable, Equatable {
    let status: String
    let reason: String?
    let method: String?
    let modelFilename: String
    let processPresetID: String
    let estimatedSeconds: Double?
    let audioDurationSeconds: Double?
    let sampleCount: Int
    let baselineGpuCoreCount: Int?
    let targetGpuCoreCount: Int?
    let secondsPerAudioSecond: Double?

    var isCalibrated: Bool {
        status == "calibrated" && estimatedSeconds != nil
    }

    var displayText: String {
        guard let estimatedSeconds, isCalibrated else {
            return "Estimate pending"
        }
        return "Est. \(FileHelpers.formattedDuration(estimatedSeconds))"
    }

    var detailText: String {
        guard isCalibrated else {
            return "Run once to calibrate"
        }
        let samples = "\(sampleCount) \(sampleCount == 1 ? "sample" : "samples")"
        if method == "heuristic" {
            return "\(samples) - similar runs, scaled"
        }
        if let baselineGpuCoreCount, let targetGpuCoreCount {
            return "\(samples) - \(baselineGpuCoreCount) -> \(targetGpuCoreCount) GPU cores"
        }
        return samples
    }

    func adding(_ other: RenderEstimate) -> RenderEstimate {
        let combinedSeconds = (self.estimatedSeconds ?? 0) + (other.estimatedSeconds ?? 0)
        return RenderEstimate(
            status: self.isCalibrated && other.isCalibrated ? "calibrated" : "pending",
            reason: self.reason,
            method: nil,
            modelFilename: self.modelFilename,
            processPresetID: self.processPresetID,
            estimatedSeconds: combinedSeconds,
            audioDurationSeconds: self.audioDurationSeconds,
            sampleCount: self.sampleCount + other.sampleCount,
            baselineGpuCoreCount: self.baselineGpuCoreCount,
            targetGpuCoreCount: self.targetGpuCoreCount,
            secondsPerAudioSecond: (self.secondsPerAudioSecond ?? 0) + (other.secondsPerAudioSecond ?? 0)
        )
    }
}

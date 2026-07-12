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

    var displayName: String {
        let baseName = stem.replacingOccurrences(of: "_", with: " ").capitalized
        let fileStem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        
        let candidates = [
            "_(" + stem + ")",
            "_(" + stem.replacingOccurrences(of: "_", with: " ") + ")"
        ]
        
        for candidate in candidates {
            if let matchRange = fileStem.range(of: candidate) {
                var modelSuffix = String(fileStem[matchRange.upperBound...])
                if modelSuffix.hasPrefix("_") {
                    modelSuffix.removeFirst()
                }
                if !modelSuffix.isEmpty {
                    let cleanedSuffix = modelSuffix.replacingOccurrences(of: "_", with: " ")
                    return "\(baseName) (\(cleanedSuffix))"
                }
            }
        }
        return baseName
    }

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
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
    let startedAt: Double?
    let completedAt: Double?
    let elapsedSeconds: Double
    let files: [StemFile]
    let metrics: [String: Double]?
    let modelCache: ModelCache?
    let settings: RunSettings?
}

struct LastRunReport {
    let summary: SeparationSummary

    var overviewRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("model", summary.model),
            ("preset", summary.preset ?? "default"),
        ]
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
        if let baselineGpuCoreCount, let targetGpuCoreCount {
            return "\(sampleCount) \(sampleCount == 1 ? "sample" : "samples") - \(baselineGpuCoreCount) -> \(targetGpuCoreCount) GPU cores"
        }
        return "\(sampleCount) \(sampleCount == 1 ? "sample" : "samples")"
    }

    func adding(_ other: RenderEstimate) -> RenderEstimate {
        let combinedSeconds = (self.estimatedSeconds ?? 0) + (other.estimatedSeconds ?? 0)
        return RenderEstimate(
            status: self.isCalibrated && other.isCalibrated ? "calibrated" : "pending",
            reason: self.reason,
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

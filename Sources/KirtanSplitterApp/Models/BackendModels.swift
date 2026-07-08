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
        stem.replacingOccurrences(of: "_", with: " ").capitalized
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
    let elapsedSeconds: Double
    let files: [StemFile]
    let metrics: [String: Double]?
    let modelCache: ModelCache?
    let settings: RunSettings?
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

    init(preset: SeparationPreset, models: [SeparatorModel], modelCache: ModelCache?) {
        let matchingModel = models.first { $0.filename == preset.modelFilename }
        let matchingGroup = modelCache?.groups?.first { group in
            Self.group(group, matches: preset.modelFilename)
        }

        isLocal = (matchingModel?.isDownloaded ?? false) || Self.isLocalCacheGroup(matchingGroup)
        usageCount = max(0, preset.usageCount ?? 0, matchingGroup?.usageCount ?? 0)
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
        if group.converted || group.hasSource || group.sourceRemoved { return true }
        return group.localState == "installed" || group.localState == "downloaded" || group.localState == "source_removed"
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
}

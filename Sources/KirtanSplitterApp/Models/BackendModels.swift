import Foundation

struct SeparationPreset: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let modelFilename: String
    let summary: String
    let expectedStems: [String]
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

struct SeparationSettings: Equatable {
    var presetID = "kirtan_pro"
    var modelOverride: String?
    var outputFormat = "FLAC"
    var speedMode = "latency_safe_v3"
    var chunkDuration: Double = 30
    var mdxcSegmentSize: Int = 256
    var mdxcOverlap: Int = 8
    var mdxcBatchSize: Int = 1
    var mdxcOverrideModelSegmentSize = false
    var saveConvertedSafetensors = true

    var chunkDurationForBackend: Double? {
        chunkDuration > 0 ? chunkDuration : nil
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

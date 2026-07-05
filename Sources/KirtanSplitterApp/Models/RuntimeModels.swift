import Foundation

struct RuntimeSnapshot: Codable, Equatable {
    let timestamp: Double?
    let cpu: CPUStats
    let memory: MemoryStats
    let process: ProcessStats
    let gpu: GPUStats
    let modelCache: ModelCacheSummary?
}

struct CPUStats: Codable, Equatable {
    let systemPercent: Double
    let aggregatePercent: Double?
    let coreCount: Int
    let loadAverage: [Double]?
}

struct MemoryStats: Codable, Equatable {
    let totalBytes: Int
    let usedBytes: Int
    let usedPercent: Double
}

struct ProcessStats: Codable, Equatable {
    let pid: Int
    let cpuPercent: Double
    let rssBytes: Int
}

struct GPUStats: Codable, Equatable {
    let device: String
    let utilizationPercent: Double?
    let powerWatts: Double?
    let gpuCoreCount: Int?
    let status: String
    let source: String?
}

struct ModelCacheSummary: Codable, Equatable {
    let modelDir: String
    let totalBytes: Int
    let itemCount: Int
    let convertedCount: Int
}

struct ModelCache: Codable, Equatable {
    let modelDir: String
    let totalBytes: Int
    let items: [ModelCacheItem]
}

struct ModelCacheItem: Identifiable, Codable, Equatable {
    var id: String { path }

    let filename: String
    let path: String
    let sizeBytes: Int
    let kind: String
    let converted: Bool
    let modifiedAt: Double
}

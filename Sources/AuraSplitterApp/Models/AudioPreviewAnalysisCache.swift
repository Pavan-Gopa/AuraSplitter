import Foundation

struct AudioPreviewAnalysisCache: Equatable {
    private var analysesByPath: [String: AudioAnalysis] = [:]
    private var errorsByPath: [String: String] = [:]
    private var analyzingPaths: Set<String> = []

    mutating func analysis(for path: String) -> AudioAnalysis? {
        if let cached = analysesByPath[path] {
            return cached
        }
        // K8: read-through from the on-disk LRU cache across app launches.
        if let disk = PreviewAnalysisDiskCache.shared.load(path: path) {
            analysesByPath[path] = disk
            return disk
        }
        return nil
    }

    func error(for path: String) -> String? {
        errorsByPath[path]
    }

    func isAnalyzing(_ path: String) -> Bool {
        analyzingPaths.contains(path)
    }

    mutating func shouldStartAnalysis(for path: String) -> Bool {
        guard analysesByPath[path] == nil, errorsByPath[path] == nil, !analyzingPaths.contains(path) else {
            return false
        }
        analyzingPaths.insert(path)
        return true
    }

    mutating func store(_ analysis: AudioAnalysis, for path: String) {
        analysesByPath[path] = analysis
        errorsByPath.removeValue(forKey: path)
        analyzingPaths.remove(path)
        // K8: persist to the on-disk LRU cache.
        PreviewAnalysisDiskCache.shared.store(analysis)
    }

    mutating func storeError(_ message: String, for path: String) {
        errorsByPath[path] = message
        analysesByPath.removeValue(forKey: path)
        analyzingPaths.remove(path)
    }

    mutating func remove(_ path: String) {
        analysesByPath.removeValue(forKey: path)
        errorsByPath.removeValue(forKey: path)
        analyzingPaths.remove(path)
    }

    mutating func removeAll() {
        analysesByPath.removeAll()
        errorsByPath.removeAll()
        analyzingPaths.removeAll()
    }
}

import CryptoKit
import Foundation

/// Disk-backed LRU cache for `AudioAnalysis` preview results.
///
/// Keyed by `SHA256(path|size|mtime|algo|resolution)` so a re-analysis is
/// skipped across app launches whenever the source file is unchanged. Bounded
/// by `maxEntries` and `maxBytes`; least-recently-used entries are evicted.
///
/// Layout: `~/Library/Caches/AuraSplitter/previews/`
/// with one `<key>.json` per entry and a persisted `lru-index.json` LRU book.
final class PreviewAnalysisDiskCache {
    static let shared = PreviewAnalysisDiskCache()

    private let directory: URL
    private let indexFile: URL
    private let maxEntries = 20
    private let maxBytes = 256 * 1024 * 1024
    private let queue = DispatchQueue(label: "com.kirtansplitter.previewdiskcache")
    private var index: [Entry] = []

    private struct Entry: Codable {
        let key: String
        let sizeBytes: Int
    }

    /// Designated initializer. `directory` is required for tests; `nil` uses
    /// the default Application Support / Caches location.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base
                .appendingPathComponent(AppBrand.folderName, isDirectory: true)
                .appendingPathComponent("previews", isDirectory: true)
        }
        self.indexFile = self.directory.appendingPathComponent("lru-index.json")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - Public API

    /// Returns a previously stored analysis for `path`, or `nil` on miss/error.
    /// Marks the entry as most-recently-used.
    func load(path: String) -> AudioAnalysis? {
        guard let key = cacheKey(forPath: path) else { return nil }
        return queue.sync {
            guard let data = try? Data(contentsOf: fileURL(forKey: key)) else { return nil }
            guard let analysis = try? JSONDecoder().decode(AudioAnalysis.self, from: data) else {
                return nil
            }
            touch(key)
            return analysis
        }
    }

    /// Non-blocking variant for use from the main actor.
    func loadAsync(path: String) async -> AudioAnalysis? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let key = self.cacheKey(forPath: path),
                      let data = try? Data(contentsOf: self.fileURL(forKey: key)),
                      let analysis = try? JSONDecoder().decode(AudioAnalysis.self, from: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.touch(key)
                continuation.resume(returning: analysis)
            }
        }
    }

    /// Persists `analysis` to disk and updates the LRU index, evicting as needed.
    func store(_ analysis: AudioAnalysis) {
        guard let key = cacheKey(forPath: analysis.path) else { return }
        queue.sync {
            let fileURL = self.fileURL(forKey: key)
            guard let data = try? JSONEncoder().encode(analysis) else { return }
            try? data.write(to: fileURL, options: .atomic)
            upsert(key: key, sizeBytes: data.count)
            enforceLimits()
        }
    }

    /// Non-blocking variant for use from the main actor.
    func storeAsync(_ analysis: AudioAnalysis) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let key = self.cacheKey(forPath: analysis.path) else {
                    continuation.resume()
                    return
                }
                let fileURL = self.fileURL(forKey: key)
                guard let data = try? JSONEncoder().encode(analysis) else {
                    continuation.resume()
                    return
                }
                try? data.write(to: fileURL, options: .atomic)
                self.upsert(key: key, sizeBytes: data.count)
                self.enforceLimits()
                continuation.resume()
            }
        }
    }

    /// Removes any cached entry for `path`.
    func remove(_ path: String) {
        guard let key = cacheKey(forPath: path) else { return }
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL(forKey: key))
            index.removeAll { $0.key == key }
            persistIndex()
        }
    }

    // MARK: - Key / file helpers

    private func cacheKey(forPath path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let discriminator = "\(path)|\(size)|\(Int64(mtime))|vdsp|8192x224"
        let digest = SHA256.hash(data: Data(discriminator.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    // MARK: - LRU index

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFile),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            index = []
            return
        }
        index = entries
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexFile, options: .atomic)
    }

    private func upsert(key: String, sizeBytes: Int) {
        index.removeAll { $0.key == key }
        index.append(Entry(key: key, sizeBytes: sizeBytes))
        persistIndex()
    }

    private func touch(_ key: String) {
        guard let existing = index.first(where: { $0.key == key }) else { return }
        index.removeAll { $0.key == key }
        index.append(existing)
        persistIndex()
    }

    private func enforceLimits() {
        var totalBytes = index.reduce(0) { $0 + $1.sizeBytes }
        while index.count > maxEntries || totalBytes > maxBytes {
            guard let oldest = index.first else { break }
            try? FileManager.default.removeItem(at: fileURL(forKey: oldest.key))
            totalBytes -= oldest.sizeBytes
            index.removeFirst()
        }
        persistIndex()
    }
}

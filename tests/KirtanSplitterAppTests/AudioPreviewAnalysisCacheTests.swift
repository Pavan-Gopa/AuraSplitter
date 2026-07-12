import XCTest
@testable import KirtanSplitterApp

final class AudioPreviewAnalysisCacheTests: XCTestCase {
    func testStoredResultAnalysisIsReturnedForRepeatedPreviewSelection() {
        var cache = AudioPreviewAnalysisCache()
        let analysis = makeAnalysis(path: "/tmp/result-vocals.wav")

        cache.store(analysis, for: analysis.path)

        XCTAssertEqual(cache.analysis(for: analysis.path), analysis)
        XCTAssertFalse(cache.shouldStartAnalysis(for: analysis.path))
    }

    func testInFlightResultAnalysisIsDeduplicated() {
        var cache = AudioPreviewAnalysisCache()
        let path = "/tmp/result-instrumental.wav"

        XCTAssertTrue(cache.shouldStartAnalysis(for: path))
        XCTAssertFalse(cache.shouldStartAnalysis(for: path))
        XCTAssertTrue(cache.isAnalyzing(path))
    }

    func testRemovingResultPathClearsAnalysisErrorAndInFlightState() {
        var cache = AudioPreviewAnalysisCache()
        let path = "/tmp/deleted-result.wav"

        XCTAssertTrue(cache.shouldStartAnalysis(for: path))
        cache.storeError("decode failed", for: path)

        cache.remove(path)

        XCTAssertNil(cache.analysis(for: path))
        XCTAssertNil(cache.error(for: path))
        XCTAssertFalse(cache.isAnalyzing(path))
        XCTAssertTrue(cache.shouldStartAnalysis(for: path))
    }

    private func makeAnalysis(path: String) -> AudioAnalysis {
        AudioAnalysis(
            path: path,
            filename: URL(fileURLWithPath: path).lastPathComponent,
            durationSeconds: 3,
            channels: 2,
            sampleRate: 44_100,
            peakDb: -3.5,
            clipped: false,
            waveformPeaks: [0.1, 0.2],
            spectrogram: SpectrogramData(columns: 1, bins: 2, values: [0.1, 0.2])
        )
    }

    func testAudioPreviewProgressAssemblesSpectrogramChunksInColumnOrder() {
        var progress = AudioPreviewProgress(path: "/tmp/prog.wav")
        progress.previewWaveform = [0.0, 1.0]

        let totalColumns = 4
        let bins = 2
        // Chunk 0 covers columns [0, 2): values laid out row-major bin rows.
        let chunk0 = SpectrogramData(columns: 2, bins: bins, values: [0.1, 0.2, 0.3, 0.4])
        progress.applySpectrogramChunk(chunk0, columnsStart: 0, totalColumns: totalColumns, totalBins: bins)
        // Chunk 1 covers columns [2, 4).
        let chunk1 = SpectrogramData(columns: 2, bins: bins, values: [0.5, 0.6, 0.7, 0.8])
        progress.applySpectrogramChunk(chunk1, columnsStart: 2, totalColumns: totalColumns, totalBins: bins)

        let assembled = progress.partialSpectrogram!
        XCTAssertEqual(assembled.columns, totalColumns)
        XCTAssertEqual(assembled.bins, bins)
        XCTAssertEqual(assembled.values, [0.1, 0.2, 0.5, 0.6, 0.3, 0.4, 0.7, 0.8])
        XCTAssertFalse(progress.isSpectrogramLoading)
    }

    func testAudioPreviewProgressCompletedWithAnalysisMirrorsFullAnalysis() {
        let analysis = makeAnalysis(path: "/tmp/done.wav")
        let progress = AudioPreviewProgress(completedWith: analysis)

        XCTAssertTrue(progress.isComplete)
        XCTAssertEqual(progress.currentWaveform, [0.1, 0.2])
        XCTAssertEqual(progress.partialSpectrogram?.values, [0.1, 0.2])
        XCTAssertFalse(progress.isSpectrogramLoading)
    }

    func testDiskCacheRestoresAnalysisAfterMemoryCacheMiss() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("disk-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 1024))
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = makeAnalysis(path: url.path)

        var memory = AudioPreviewAnalysisCache()
        memory.store(analysis, for: analysis.path)

        // A fresh in-memory cache (no entry) should still recover from disk LRU.
        var fresh = AudioPreviewAnalysisCache()
        let restored = fresh.analysis(for: analysis.path)

        XCTAssertEqual(restored?.path, analysis.path)
        XCTAssertEqual(restored?.waveformPeaks, analysis.waveformPeaks)
    }

    func testDiskCacheEvictsLeastRecentlyUsed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lru-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = PreviewAnalysisDiskCache(directory: dir)

        let firstURL = dir.appendingPathComponent("s0.wav")
        FileManager.default.createFile(atPath: firstURL.path, contents: Data(repeating: 0, count: 1024))
        let lastURL = dir.appendingPathComponent("s21.wav")
        FileManager.default.createFile(atPath: lastURL.path, contents: Data(repeating: 0, count: 1024))

        // Store 22 analyses; the LRU cap (20) should evict the earliest.
        for i in 0..<22 {
            let url = dir.appendingPathComponent("s\(i).wav")
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: UInt8(i), count: 1024))
            disk.store(makeAnalysis(path: url.path))
        }

        XCTAssertNil(disk.load(path: firstURL.path))
        XCTAssertNotNil(disk.load(path: lastURL.path))
    }
}

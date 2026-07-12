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
}

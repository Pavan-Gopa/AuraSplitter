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
}

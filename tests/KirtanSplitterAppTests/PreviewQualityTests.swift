import XCTest
@testable import KirtanSplitterApp

final class PreviewQualityTests: XCTestCase {
    func testSeparationDefaultsUseWavOutput() {
        XCTAssertEqual(SeparationSettings().outputFormat, "WAV")
    }

    func testAudioPreviewRequestsHighResolutionAnalysis() {
        XCTAssertGreaterThanOrEqual(AudioPreviewAnalysisResolution.waveformPoints, 4096)
        XCTAssertGreaterThanOrEqual(AudioPreviewAnalysisResolution.spectrogramColumns, 4096)
        XCTAssertGreaterThanOrEqual(AudioPreviewAnalysisResolution.spectrogramBins, 192)
    }
}

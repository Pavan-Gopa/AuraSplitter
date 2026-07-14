import XCTest
@testable import AuraSplitterApp

final class PreviewQualityTests: XCTestCase {
    func testSeparationDefaultsUseWavOutput() {
        XCTAssertEqual(SeparationSettings().outputFormat, "WAV")
    }

    func testChangingSegmentSizeAutomaticallyOverridesModelSegment() {
        var settings = SeparationSettings()
        XCTAssertFalse(settings.effectiveMDXCOverrideModelSegmentSize)

        settings.mdxcSegmentSize = 512

        XCTAssertTrue(settings.effectiveMDXCOverrideModelSegmentSize)
    }

    func testAudioPreviewRequestsHighResolutionAnalysis() {
        XCTAssertGreaterThanOrEqual(AudioPreviewAnalysisResolution.waveformPoints, 4096)
        XCTAssertGreaterThanOrEqual(AudioPreviewAnalysisResolution.spectrogramColumns, 4096)
        XCTAssertGreaterThanOrEqual(AudioPreviewAnalysisResolution.spectrogramBins, 192)
    }
}

import XCTest
@testable import KirtanSplitterApp

final class AudioPreviewControlsTests: XCTestCase {
    func testVolumeClampKeepsPreviewGainBetweenMuteAndTripleGain() {
        XCTAssertEqual(AudioPreviewVolume.clamp(-0.5), 0)
        XCTAssertEqual(AudioPreviewVolume.clamp(1.25), 1.25)
        XCTAssertEqual(AudioPreviewVolume.clamp(4.0), 3)
    }

    func testPreviewHeightFractionStartsAtThirtyFivePercentAndStopsAtHalfWindow() {
        XCTAssertEqual(AudioPreviewLayout.defaultBottomFraction, 0.35)
        XCTAssertEqual(AudioPreviewLayout.clampedBottomFraction(0.1), 0.35)
        XCTAssertEqual(AudioPreviewLayout.clampedBottomFraction(0.44), 0.44)
        XCTAssertEqual(AudioPreviewLayout.clampedBottomFraction(0.8), 0.5)
    }

    func testLayerSettingsDefaultToFullSpectrumAndWaveformIntensity() {
        let settings = AudioPreviewLayerSettings()

        XCTAssertEqual(settings.spectrumIntensity, 1)
        XCTAssertEqual(settings.waveformIntensity, 1)
    }

    func testLayerSettingsClampIntensityBetweenHiddenAndDouble() {
        XCTAssertEqual(AudioPreviewLayerSettings.clampIntensity(-0.3), 0)
        XCTAssertEqual(AudioPreviewLayerSettings.clampIntensity(1.4), 1.4)
        XCTAssertEqual(AudioPreviewLayerSettings.clampIntensity(3.0), 2)
    }
}

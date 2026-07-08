import XCTest
@testable import KirtanSplitterApp

final class AudioAnalysisMetadataTests: XCTestCase {
    func testAudioAnalysisDecodesSeparationMetadataAndBuildsDisplayLabel() throws {
        let data = Data(
            """
            {
              "path": "/tmp/01MAIN_V_(Vocals).wav",
              "filename": "01MAIN_V_(Vocals).wav",
              "durationSeconds": 12.5,
              "channels": 1,
              "sampleRate": 48000,
              "bitDepth": 24,
              "peakDb": -13.1,
              "clipped": false,
              "waveformPeaks": [0.1],
              "spectrogram": {"columns": 1, "bins": 1, "values": [0.2]},
              "separationModelName": "Kirtan Pro",
              "separationModelCheckpoint": "BS-Roformer-SW.ckpt",
              "separationPresetID": "kirtan_pro",
              "separationProcessPresetTitle": "Heavy 1024"
            }
            """.utf8
        )

        let analysis = try JSONDecoder().decode(AudioAnalysis.self, from: data)

        XCTAssertEqual(analysis.sampleRate, 48_000)
        XCTAssertEqual(analysis.bitDepthLabel, "24 bit")
        XCTAssertEqual(analysis.separationModelName, "Kirtan Pro")
        XCTAssertEqual(analysis.separationModelLabel, "Kirtan Pro")
    }
}

import XCTest
@testable import AuraSplitterApp

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
              "separationModelName": "Aura Pro",
              "separationModelCheckpoint": "BS-Roformer-SW.ckpt",
              "separationPresetID": "kirtan_pro",
              "separationProcessPresetTitle": "Heavy 1024"
            }
            """.utf8
        )

        let analysis = try JSONDecoder().decode(AudioAnalysis.self, from: data)

        XCTAssertEqual(analysis.sampleRate, 48_000)
        XCTAssertEqual(analysis.bitDepthLabel, "24 bit")
        XCTAssertEqual(analysis.separationModelName, "Aura Pro")
        XCTAssertEqual(analysis.separationModelLabel, "Aura Pro")
    }

    func testAudioAnalysisReadsKsbinPayload() throws {
        let waveform: [Float32] = [0.0, 0.5, 1.0, 0.25]
        let columns = 8
        let bins = 4
        var spectrogram = [Float32](repeating: 0, count: columns * bins)
        for bin in 0..<bins {
            for column in 0..<columns {
                spectrogram[bin * columns + column] = Float32((bin * columns + column) % 7) / 7.0
            }
        }

        var data = Data()
        data.append(1)
        var waveformCount = UInt32(waveform.count).littleEndian
        var columnsValue = UInt32(columns).littleEndian
        var binsValue = UInt32(bins).littleEndian
        data.append(Data(bytes: &waveformCount, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &columnsValue, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &binsValue, count: MemoryLayout<UInt32>.size))
        data.append(waveform.withUnsafeBytes { Data($0) })
        data.append(spectrogram.withUnsafeBytes { Data($0) })

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kirtan-ksbin-test-\(UUID().uuidString).ksbin")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try AudioAnalysis.readKsbin(at: url)
        XCTAssertEqual(payload.waveformPeaks.count, 4)
        XCTAssertEqual(payload.spectrogram.columns, columns)
        XCTAssertEqual(payload.spectrogram.bins, bins)
        XCTAssertEqual(payload.spectrogram.values.count, columns * bins)
        XCTAssertEqual(payload.waveformPeaks[1], 0.5, accuracy: 1e-6)
    }
}

import AVFoundation
import XCTest

@testable import KirtanSplitterApp

final class LocalAudioAnalyzerTests: XCTestCase {
    private func makeSineWav(url: URL, channels: Int, duration: Double = 2.0, frequency: Double = 440) throws {
        let sampleRate = 44100.0
        let frames = Int(sampleRate * duration)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let channelData = buffer.floatChannelData else {
            XCTFail("failed to allocate channel data")
            return
        }
        for c in 0..<channels {
            let pointer = channelData[c]
            for i in 0..<frames {
                let phase = 2 * Double.pi * frequency * Double(i) / sampleRate
                pointer[i] = Float(sin(phase) * 0.5)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testAnalyzeMonoDimensionsAndRange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local_analyzer_mono_\(UUID().uuidString).wav")
        try makeSineWav(url: url, channels: 1)

        let analysis = try LocalAudioAnalyzer.analyze(url: url)

        XCTAssertEqual(analysis.channels, 1)
        XCTAssertEqual(analysis.sampleRate, 44100)
        XCTAssertGreaterThan(analysis.durationSeconds, 1.5)
        XCTAssertLessThan(analysis.durationSeconds, 2.5)

        let peaks = try XCTUnwrap(analysis.waveformPeaks)
        XCTAssertEqual(peaks.count, AudioPreviewAnalysisResolution.waveformPoints)
        XCTAssertTrue(peaks.allSatisfy { $0 >= 0 && $0 <= 1 })

        let spectrogram = try XCTUnwrap(analysis.spectrogram)
        XCTAssertEqual(spectrogram.columns, AudioPreviewAnalysisResolution.spectrogramColumns)
        XCTAssertEqual(spectrogram.bins, AudioPreviewAnalysisResolution.spectrogramBins)
        XCTAssertEqual(spectrogram.values.count, spectrogram.bins * spectrogram.columns)
        XCTAssertTrue(spectrogram.values.allSatisfy { $0 >= -160 && $0 <= 10 })

        try FileManager.default.removeItem(at: url)
    }

    func testAnalyzeStereoMixesDownAndProducesSpectrogram() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local_analyzer_stereo_\(UUID().uuidString).wav")
        try makeSineWav(url: url, channels: 2)

        let analysis = try LocalAudioAnalyzer.analyze(url: url)

        XCTAssertEqual(analysis.channels, 2)
        XCTAssertEqual(try XCTUnwrap(analysis.spectrogram).bins, AudioPreviewAnalysisResolution.spectrogramBins)
        XCTAssertEqual(try XCTUnwrap(analysis.spectrogram).columns, AudioPreviewAnalysisResolution.spectrogramColumns)

        try FileManager.default.removeItem(at: url)
    }

    func testCanAnalyzeLocallyThreshold() throws {
        let small = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiny_\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: small.path, contents: Data())
        XCTAssertTrue(LocalAudioAnalyzer.canAnalyzeLocally(small))

        let huge = FileManager.default.temporaryDirectory
            .appendingPathComponent("huge_\(UUID().uuidString).wav")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/truncate")
        task.arguments = ["-s", "\(LocalAudioAnalyzer.localMaxBytes + 1)", huge.path]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        XCTAssertFalse(LocalAudioAnalyzer.canAnalyzeLocally(huge))

        try? FileManager.default.removeItem(at: small)
        try? FileManager.default.removeItem(at: huge)
    }
}

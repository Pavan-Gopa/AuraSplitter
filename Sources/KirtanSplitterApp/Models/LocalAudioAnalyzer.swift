import Accelerate
import AVFoundation
import Foundation

/// On-device audio analysis using Accelerate/vDSP.
///
/// Produces the same `AudioAnalysis` shape (WaveformPeaks + SpectrogramData)
/// as the backend `analyze_audio` endpoint, but runs entirely on the CPU via
/// vDSP FFT. This keeps typical-track preview generation local (RX-class,
/// no Python round-trip). Huge files fall back to the backend binary path
/// (see `BackendClient.analyzeAudio`).
enum LocalAudioAnalyzer {
    /// Files larger than this are delegated to the backend progressive path.
    static let localMaxBytes: Int64 = 200 * 1024 * 1024

    enum AnalysisError: Error { case unreadable, empty, fileTooLarge }

    /// Cheap pre-check: small enough to attempt locally.
    static func canAnalyzeLocally(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size <= localMaxBytes
    }

    static func analyze(url: URL) throws -> AudioAnalysis {
        guard canAnalyzeLocally(url) else { throw AnalysisError.fileTooLarge }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let sampleRate = Int(format.sampleRate)
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { throw AnalysisError.empty }

        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        )!
        _ = try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.floatChannelData else {
            throw AnalysisError.empty
        }

        var mono = [Float](repeating: 0, count: frames)
        if channels == 1 {
            let src = channelData[0]
            for i in 0..<frames { mono[i] = src[i] }
        } else {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += channelData[c][i] }
                mono[i] = sum / Float(channels)
            }
        }

        let duration = Double(frames) / Double(sampleRate)
        let (peakDb, clipped) = Self.measurePeak(mono)
        let waveformPeaks = Self.computeWaveformPeaks(mono)
        let spectrogram = Self.computeSpectrogram(mono, sampleRate: sampleRate)

        return AudioAnalysis(
            path: url.path,
            filename: url.lastPathComponent,
            durationSeconds: duration,
            channels: channels,
            sampleRate: sampleRate,
            bitDepth: nil,
            peakDb: peakDb,
            clipped: clipped,
            waveformPeaks: waveformPeaks,
            spectrogram: spectrogram,
            separationModelName: nil,
            separationModelCheckpoint: nil,
            separationPresetID: nil,
            separationProcessPresetTitle: nil,
            binaryPayloadPath: nil
        )
    }

    private static func measurePeak(_ mono: [Float]) -> (db: Double, clipped: Bool) {
        var maxAbs: Float = 0
        vDSP_maxmgv(mono, 1, &maxAbs, vDSP_Length(mono.count))
        let clipped = maxAbs >= 0.999
        let db = maxAbs > 0 ? 20 * log10(Double(maxAbs)) : -120
        return (max(db, -120), clipped)
    }

    private static func computeWaveformPeaks(_ mono: [Float]) -> [Double] {
        let points = AudioPreviewAnalysisResolution.waveformPoints
        var peaks = [Double](repeating: 0, count: points)
        let frames = mono.count
        guard frames > 0 else { return peaks }
        let bucket = max(1, frames / points)
        for i in 0..<frames {
            let b = min(points - 1, i / bucket)
            let a = Double(abs(mono[i]))
            if a > peaks[b] { peaks[b] = a }
        }
        return peaks
    }

    private static func computeSpectrogram(_ mono: [Float], sampleRate _: Int) -> SpectrogramData {
        let columns = AudioPreviewAnalysisResolution.spectrogramColumns
        let bins = AudioPreviewAnalysisResolution.spectrogramBins
        let frames = mono.count

        let fftSize = nextPowerOfTwo(bins * 2)
        let log2n = Int(log2(Double(fftSize)))
        let window = hannWindow(size: fftSize)
        let fft = vDSP.FFT(log2n: vDSP_Length(log2n), radix: .radix2, ofType: DSPSplitComplex.self)!

        var realInput = [Float](repeating: 0, count: fftSize)
        var imagInput = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        var values = [Double](repeating: 0, count: bins * columns)
        let usableSpan = max(0, frames - fftSize)

        realInput.withUnsafeMutableBufferPointer { rip in
            imagInput.withUnsafeMutableBufferPointer { iip in
                outReal.withUnsafeMutableBufferPointer { orp in
                    outImag.withUnsafeMutableBufferPointer { oip in
                        var inputSplit = DSPSplitComplex(realp: rip.baseAddress!, imagp: iip.baseAddress!)
                        var outSplit = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)

                        for col in 0..<columns {
                            let center = Int(Double(col) / Double(max(1, columns - 1)) * Double(usableSpan))
                            let start = max(0, min(frames - fftSize, center))
                            for i in 0..<fftSize {
                                let idx = start + i
                                rip.baseAddress![i] = idx < frames ? mono[idx] * window[i] : 0
                                iip.baseAddress![i] = 0
                            }
                            fft.forward(input: inputSplit, output: &outSplit)
                            for bin in 0..<bins {
                                let re = orp.baseAddress![bin]
                                let im = oip.baseAddress![bin]
                                let mag = sqrt(re * re + im * im)
                                let db = 20 * log10(max(Double(mag), 1e-7))
                                let norm = max(0, min(1, (db + 90) / 90))
                                values[bin * columns + col] = norm
                            }
                        }
                    }
                }
            }
        }

        return SpectrogramData(columns: columns, bins: bins, values: values)
    }

    private static func hannWindow(size: Int) -> [Float] {
        (0..<size).map { i in
            Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(max(1, size - 1)))))
        }
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var v = max(1, value)
        v -= 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        return v + 1
    }
}

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

    private static func computeSpectrogram(_ mono: [Float], sampleRate: Int) -> SpectrogramData {
        let columns = AudioPreviewAnalysisResolution.spectrogramColumns
        let bins = AudioPreviewAnalysisResolution.spectrogramBins
        let frames = mono.count

        let fftSize = 2048
        let log2n = Int(log2(Double(fftSize)))
        let window = hannWindow(size: fftSize)
        let fft = vDSP.FFT(log2n: vDSP_Length(log2n), radix: .radix2, ofType: DSPSplitComplex.self)!

        let halfSize = fftSize / 2
        var realInput = [Float](repeating: 0, count: halfSize)
        var imagInput = [Float](repeating: 0, count: halfSize)
        var outReal = [Float](repeating: 0, count: halfSize)
        var outImag = [Float](repeating: 0, count: halfSize)

        var dbValues = [Double](repeating: 0, count: bins * columns)
        let usableSpan = max(0, frames - fftSize)

        // Mel scale mapping parameters (matching human pitch perception, like iZotope RX)
        let fMin = 20.0
        let fMax = Double(sampleRate) / 2.0
        let melMin = 2595.0 * log10(1.0 + fMin / 700.0)
        let melMax = 2595.0 * log10(1.0 + fMax / 700.0)
        
        var targetIndices = [Double](repeating: 0, count: bins)
        for bin in 0..<bins {
            let mel = melMin + (Double(bin) / Double(max(1, bins - 1))) * (melMax - melMin)
            let freq = 700.0 * (pow(10.0, mel / 2595.0) - 1.0)
            targetIndices[bin] = freq / Double(sampleRate) * Double(fftSize)
        }

        // Compute boundary indices for max-pooling
        var boundaries = [Double](repeating: 0, count: bins + 1)
        boundaries[0] = max(0.0, targetIndices[0] - (targetIndices[1] - targetIndices[0]) / 2.0)
        for i in 1..<bins {
            boundaries[i] = (targetIndices[i - 1] + targetIndices[i]) / 2.0
        }
        boundaries[bins] = targetIndices[bins - 1] + (targetIndices[bins - 1] - targetIndices[bins - 2]) / 2.0

        realInput.withUnsafeMutableBufferPointer { rip in
            imagInput.withUnsafeMutableBufferPointer { iip in
                outReal.withUnsafeMutableBufferPointer { orp in
                    outImag.withUnsafeMutableBufferPointer { oip in
                        let inputSplit = DSPSplitComplex(realp: rip.baseAddress!, imagp: iip.baseAddress!)
                        var outSplit = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)

                        for col in 0..<columns {
                            let center = Int(Double(col) / Double(max(1, columns - 1)) * Double(usableSpan))
                            let start = max(0, min(frames - fftSize, center))
                            
                            // Pack real samples into split complex input (even in realp, odd in imagp)
                            for i in 0..<halfSize {
                                let idx1 = start + 2 * i
                                let idx2 = start + 2 * i + 1
                                rip.baseAddress![i] = idx1 < frames ? mono[idx1] * window[2 * i] : 0
                                iip.baseAddress![i] = idx2 < frames ? mono[idx2] * window[2 * i + 1] : 0
                            }
                            
                            fft.forward(input: inputSplit, output: &outSplit)
                            
                            for bin in 0..<bins {
                                let left = boundaries[bin]
                                let right = boundaries[bin + 1]
                                let leftInt = Int(ceil(left))
                                let rightInt = Int(floor(right))
                                
                                var mag: Float = 0.0
                                if leftInt <= rightInt {
                                    // Max pooling over the range [leftInt, rightInt]
                                    var maxMag: Float = 0.0
                                    for idx in leftInt...rightInt {
                                        let cIdx = max(0, min(halfSize, idx))
                                        let m: Float
                                        if cIdx == 0 {
                                            m = abs(orp.baseAddress![0])
                                        } else if cIdx == halfSize {
                                            m = abs(oip.baseAddress![0])
                                        } else {
                                            let re = orp.baseAddress![cIdx]
                                            let im = oip.baseAddress![cIdx]
                                            m = sqrt(re * re + im * im)
                                        }
                                        if m > maxMag { maxMag = m }
                                    }
                                    mag = maxMag
                                } else {
                                    // Linear interpolation at the center index
                                    let center = targetIndices[bin]
                                    let idxFloor = max(0, min(halfSize, Int(floor(center))))
                                    let idxCeil = max(0, min(halfSize, idxFloor + 1))
                                    let t = Float(center - Double(idxFloor))
                                    
                                    let mag1: Float
                                    if idxFloor == 0 {
                                        mag1 = abs(orp.baseAddress![0])
                                    } else if idxFloor == halfSize {
                                        mag1 = abs(oip.baseAddress![0])
                                    } else {
                                        let re = orp.baseAddress![idxFloor]
                                        let im = oip.baseAddress![idxFloor]
                                        mag1 = sqrt(re * re + im * im)
                                    }
                                    
                                    let mag2: Float
                                    if idxCeil == 0 {
                                        mag2 = abs(orp.baseAddress![0])
                                    } else if idxCeil == halfSize {
                                        mag2 = abs(oip.baseAddress![0])
                                    } else {
                                        let re = orp.baseAddress![idxCeil]
                                        let im = oip.baseAddress![idxCeil]
                                        mag2 = sqrt(re * re + im * im)
                                    }
                                    
                                    mag = mag1 + (mag2 - mag1) * t
                                }
                                
                                let db = 20 * log10(max(Double(mag) / Double(halfSize), 1e-10))
                                dbValues[bin * columns + col] = db
                            }
                        }
                    }
                }
            }
        }

        return SpectrogramData(columns: columns, bins: bins, values: dbValues)
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

import Foundation

struct AudioAnalysis: Codable, Equatable {
    let path: String
    let filename: String
    let durationSeconds: Double
    let channels: Int
    let sampleRate: Int
    var bitDepth: Int? = nil
    let peakDb: Double
    let clipped: Bool
    var waveformPeaks: [Double]? = nil
    var spectrogram: SpectrogramData? = nil
    var separationModelName: String? = nil
    var separationModelCheckpoint: String? = nil
    var separationPresetID: String? = nil
    var separationProcessPresetTitle: String? = nil
    var binaryPayloadPath: String? = nil

    var channelLabel: String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(channels) channels"
        }
    }

    var peakLabel: String {
        "\(String(format: "%.1f", peakDb)) dBFS"
    }

    var bitDepthLabel: String? {
        guard let bitDepth, bitDepth > 0 else { return nil }
        return "\(bitDepth) bit"
    }

    var separationModelLabel: String? {
        if let separationModelName, !separationModelName.isEmpty {
            return separationModelName
        }
        if let separationModelCheckpoint, !separationModelCheckpoint.isEmpty {
            return URL(fileURLWithPath: separationModelCheckpoint).deletingPathExtension().lastPathComponent
        }
        return nil
    }
}

struct SpectrogramData: Codable, Equatable {
    let columns: Int
    let bins: Int
    let values: [Double]
}

extension Data {
    fileprivate func loadLittleEndianUInt32(from offset: Int) -> UInt32 {
        let sub = self.subdata(in: offset..<offset + 4)
        return sub.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }
}

extension AudioAnalysis {
    enum KsbinReadError: Error { case invalidFormat, truncated }

    static func readKsbin(at url: URL) throws -> (waveformPeaks: [Double], spectrogram: SpectrogramData) {
        let data = try Data(contentsOf: url)
        guard data.count >= 13 else { throw KsbinReadError.truncated }
        var cursor = 0
        let version = data[cursor]
        cursor += 1
        guard version == 1 else { throw KsbinReadError.invalidFormat }
        let waveformCount = data.loadLittleEndianUInt32(from: cursor)
        cursor += 4
        let columns = data.loadLittleEndianUInt32(from: cursor)
        cursor += 4
        let bins = data.loadLittleEndianUInt32(from: cursor)
        cursor += 4
        let waveformByteCount = Int(waveformCount) * 4
        let spectrogramByteCount = Int(columns) * Int(bins) * 4
        guard data.count >= cursor + waveformByteCount + spectrogramByteCount else { throw KsbinReadError.truncated }
        let waveformFloats = data.subdata(in: cursor..<cursor + waveformByteCount)
            .withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        cursor += waveformByteCount
        let spectrogramFloats = data.subdata(in: cursor..<cursor + spectrogramByteCount)
            .withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        return (
            waveformFloats.map { Double($0) },
            SpectrogramData(columns: Int(columns), bins: Int(bins), values: spectrogramFloats.map { Double($0) })
        )
    }
}

enum AudioPreviewPhase: String, Codable, Equatable {
    case idle
    case waveformPreview
    case waveformFull
    case spectrogramChunking
    case complete
}

struct AudioPreviewProgress {
    let path: String
    var phase: AudioPreviewPhase = .waveformPreview
    var previewWaveform: [Double]?
    var fullWaveform: [Double]?
    var partialSpectrogram: SpectrogramData?
    var isSpectrogramLoading: Bool = true
    var durationSeconds: Double = 0
    var channels: Int = 0
    var sampleRate: Int = 0
    var peakDb: Double = 0
    var clipped: Bool = false

    var isComplete: Bool { phase == .complete }
    var currentWaveform: [Double]? { fullWaveform ?? previewWaveform }

    init(path: String) {
        self.path = path
    }

    init(completedWith analysis: AudioAnalysis) {
        self.path = analysis.path
        self.phase = .complete
        self.fullWaveform = analysis.waveformPeaks
        self.previewWaveform = analysis.waveformPeaks
        self.partialSpectrogram = analysis.spectrogram
        self.isSpectrogramLoading = false
        self.durationSeconds = analysis.durationSeconds
        self.channels = analysis.channels
        self.sampleRate = analysis.sampleRate
        self.peakDb = analysis.peakDb
        self.clipped = analysis.clipped
    }

    mutating func applySpectrogramChunk(_ chunk: SpectrogramData, columnsStart: Int, totalColumns: Int, totalBins: Int) {
        let count = chunk.columns
        var values = partialSpectrogram?.values ?? []
        if values.count != totalColumns * totalBins {
            values = [Double](repeating: 0, count: totalColumns * totalBins)
        }
        var index = 0
        for bin in 0..<totalBins {
            let base = bin * totalColumns + columnsStart
            for local in 0..<count {
                values[base + local] = chunk.values[index]
                index += 1
            }
        }
        partialSpectrogram = SpectrogramData(columns: totalColumns, bins: totalBins, values: values)
        isSpectrogramLoading = false
    }
}

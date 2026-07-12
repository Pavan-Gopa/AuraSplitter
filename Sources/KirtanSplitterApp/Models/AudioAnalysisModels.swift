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

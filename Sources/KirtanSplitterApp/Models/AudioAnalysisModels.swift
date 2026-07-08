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
    let waveformPeaks: [Double]
    let spectrogram: SpectrogramData
    var separationModelName: String? = nil
    var separationModelCheckpoint: String? = nil
    var separationPresetID: String? = nil
    var separationProcessPresetTitle: String? = nil

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

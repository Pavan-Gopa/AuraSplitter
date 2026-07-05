import Foundation

struct AudioAnalysis: Codable, Equatable {
    let path: String
    let filename: String
    let durationSeconds: Double
    let channels: Int
    let sampleRate: Int
    let peakDb: Double
    let clipped: Bool
    let waveformPeaks: [Double]
    let spectrogram: SpectrogramData

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
}

struct SpectrogramData: Codable, Equatable {
    let columns: Int
    let bins: Int
    let values: [Double]
}

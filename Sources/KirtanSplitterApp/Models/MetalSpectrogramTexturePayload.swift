import Foundation

/// Metal texture payload for the spectrogram layer.
///
/// `SpectrogramData.values` is stored **row-major with frequency bins as rows**
/// (`values[bin * columns + col]`). Both the backend `analyze_audio` (ksbin)
/// and the on-device `LocalAudioAnalyzer` (vDSP) produce this exact layout, so
/// no transpose is needed here — only a `[0, 1]` clamp. `width` maps to time
/// (columns) and `height` maps to frequency (bins).
struct MetalSpectrogramTexturePayload: Equatable {
    let width: Int
    let height: Int
    let floats: [Float]

    init?(spectrogram: SpectrogramData) {
        let columns = max(1, spectrogram.columns)
        let bins = max(1, spectrogram.bins)
        guard spectrogram.values.count >= columns * bins else { return nil }

        // The backend emits spectrogram values already row-major with bin rows:
        // values[bin * columns + column]. That is exactly the row-major layout
        // a Metal texture (width=columns, height=bins) expects, so we copy
        // straight through and only clamp into [0, 1]. No O(N) transpose.
        let neededCount = columns * bins
        var nextFloats: [Float] = []
        nextFloats.reserveCapacity(neededCount)
        for index in 0..<neededCount {
            let value = spectrogram.values[index]
            nextFloats.append(Float(min(1, max(0, value))))
        }

        width = columns
        height = bins
        floats = nextFloats
    }
}

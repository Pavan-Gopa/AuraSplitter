import Foundation

struct MetalSpectrogramTexturePayload: Equatable {
    let width: Int
    let height: Int
    let floats: [Float]

    init?(spectrogram: SpectrogramData) {
        let columns = max(1, spectrogram.columns)
        let bins = max(1, spectrogram.bins)
        guard spectrogram.values.count >= columns * bins else { return nil }

        var nextFloats: [Float] = []
        nextFloats.reserveCapacity(columns * bins)
        for bin in 0..<bins {
            for column in 0..<columns {
                let index = column * bins + bin
                let value = min(1, max(0, spectrogram.values[index]))
                nextFloats.append(Float(value))
            }
        }

        width = columns
        height = bins
        floats = nextFloats
    }
}

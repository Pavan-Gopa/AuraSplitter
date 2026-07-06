import CoreGraphics
import Foundation

enum SpectrogramImageRenderer {
    static func makeImage(from spectrogram: SpectrogramData) -> CGImage? {
        let columns = max(1, spectrogram.columns)
        let bins = max(1, spectrogram.bins)
        guard spectrogram.values.count >= columns * bins else { return nil }

        var pixels = Data(count: columns * bins * 4)
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let buffer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<bins {
                let sourceBin = bins - 1 - y
                for x in 0..<columns {
                    let value = spectrogram.values[x * bins + sourceBin]
                    let color = rgba(for: value)
                    let offset = (y * columns + x) * 4
                    buffer[offset] = color.red
                    buffer[offset + 1] = color.green
                    buffer[offset + 2] = color.blue
                    buffer[offset + 3] = 255
                }
            }
        }

        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: columns,
            height: bins,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: columns * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func rgba(for rawValue: Double) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let value = pow(min(1, max(0, rawValue)), 0.82)
        if value < 0.22 {
            let t = value / 0.22
            return (
                byte(0.01 + 0.03 * t),
                byte(0.018 + 0.07 * t),
                byte(0.05 + 0.28 * t)
            )
        }
        if value < 0.58 {
            let t = (value - 0.22) / 0.36
            return (
                byte(0.04 + 0.72 * t),
                byte(0.09 + 0.30 * t),
                byte(0.33 - 0.20 * t)
            )
        }
        let t = (value - 0.58) / 0.42
        return (
            byte(0.76 + 0.24 * t),
            byte(0.39 + 0.40 * t),
            byte(0.13 + 0.03 * t)
        )
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8((min(1, max(0, value)) * 255).rounded())
    }
}

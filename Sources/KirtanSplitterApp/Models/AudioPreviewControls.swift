import Foundation

enum AudioPreviewVolume {
    static func clamp(_ value: Double) -> Double {
        min(3, max(0, value))
    }
}

enum AudioPreviewLayout {
    static let defaultBottomFraction: CGFloat = 0.35
    static let maximumBottomFraction: CGFloat = 0.50

    static func clampedBottomFraction(_ value: CGFloat) -> CGFloat {
        min(maximumBottomFraction, max(defaultBottomFraction, value))
    }
}

struct AudioPreviewLayerSettings: Equatable {
    var spectrumIntensity: Double = 1
    var waveformIntensity: Double = 1

    static func clampIntensity(_ value: Double) -> Double {
        min(2, max(0, value))
    }
}

import SwiftUI

/// Single source of truth for visual design tokens.
///
/// Replaces the hardcoded `Color(red:...)` literals and ad-hoc padding/corner
/// values scattered through the chrome with named, consistent tokens. Keep this
/// file the only place that owns raw color/spacing/radius constants.
enum KSTheme {
    // MARK: — Backgrounds
    static let canvasBackground = Color(red: 0.015, green: 0.018, blue: 0.026)
    static let panelBackground = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let surfaceBackground = Color(red: 0.08, green: 0.10, blue: 0.14)

    // MARK: — Accents
    static let accent = Color.orange
    static let waveformBlue = Color(red: 0.18, green: 0.55, blue: 1.0)
    /// Matches spectrogram fire colormap (amber / orange) for layer controls.
    static let spectrogramAccent = Color(red: 1.0, green: 0.52, blue: 0.12)
    static let playheadAmber = Color(red: 1.0, green: 0.74, blue: 0.18)
    static let clippingRed = Color(red: 1.0, green: 0.22, blue: 0.20)
    static let decibelPink = Color(red: 1.0, green: 0.18, blue: 0.32)

    // MARK: — Hairlines & shimmer
    static let hairline = Color.white.opacity(0.06)
    static let shimmerColors: [Color] = [.clear, Color.white.opacity(0.05), .clear]

    // MARK: — Spacing
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 12
    static let spacingLG: CGFloat = 16
    static let spacingXL: CGFloat = 20
    static let spacingXXL: CGFloat = 24

    // MARK: — Corner radii
    static let radiusSM: CGFloat = 6
    static let radiusMD: CGFloat = 10
    static let radiusLG: CGFloat = 14
}

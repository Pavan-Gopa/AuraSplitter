import SwiftUI

/// Shared SF Symbol + color for stem roles (Results list + Automation matrix).
enum StemRoleStyle {
    static func baseKind(from stem: String) -> String {
        stem
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"_\d+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "_")
    }

    static func systemImage(for stem: String) -> String {
        let kind = baseKind(from: stem)
        switch kind {
        case "vocals", "vocal", "lead_vocals", "lead", "lead_vocal", "back_vocals", "back_vocal", "backing_vocals":
            return "mic.fill"
        case "drums", "drum", "kick", "snare", "toms", "percussion":
            return "music.quarternote.3"
        case "bass":
            return "waveform.path.badge.minus"
        case "piano", "keys", "keys_piano":
            return "pianokeys"
        case "guitar", "guitars", "electric_guitar", "acoustic_guitar":
            return "guitars"
        case "sitar":
            return "music.note"
        case "instrumental", "instruments", "no_drums", "no drums", "other", "rest":
            return "waveform"
        default:
            if kind.contains("vocal") || kind.contains("lead") || kind.contains("back") {
                return "mic.fill"
            }
            if kind.contains("drum") {
                return "music.quarternote.3"
            }
            return "waveform"
        }
    }

    static func color(for stem: String) -> Color {
        let kind = baseKind(from: stem)
        switch kind {
        case "vocals", "vocal", "lead_vocals", "lead", "lead_vocal", "back_vocals", "back_vocal", "backing_vocals":
            return .orange
        case "drums", "drum", "kick", "snare", "toms", "percussion":
            return .red
        case "bass":
            return .purple
        case "piano", "keys", "keys_piano":
            return .green
        case "guitar", "guitars", "electric_guitar", "acoustic_guitar":
            return .cyan
        case "sitar":
            return .yellow
        case "instrumental", "instruments":
            return .mint
        case "no_drums", "no drums":
            return .indigo
        case "other", "rest":
            return .blue
        default:
            if kind.contains("vocal") || kind.contains("lead") || kind.contains("back") {
                return .orange
            }
            if kind.contains("drum") {
                return .red
            }
            return .blue
        }
    }

    static func accessibilityLabel(for stem: String) -> String {
        stem.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

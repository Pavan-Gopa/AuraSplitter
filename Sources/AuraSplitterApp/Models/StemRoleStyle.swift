import SwiftUI

/// Shared SF Symbol + color for stem roles (Results list + Automation matrix).
/// Each instrument role should read as a distinct icon + hue.
enum StemRoleStyle {
    static func baseKind(from stem: String) -> String {
        stem
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"_\d+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    static func systemImage(for stem: String) -> String {
        let kind = baseKind(from: stem)

        // Vocals (lead vs back first)
        if isBackVocal(kind) { return "person.2.fill" }
        if isLeadVocal(kind) { return "mic.fill" }

        switch kind {
        // —— Vocals / speech ——
        case "vocals", "vocal":
            return "mic.fill"
        case "speech", "speak", "dialogue":
            return "text.bubble.fill"

        // —— Drums / percussion (each piece unique) ——
        case "kick", "kick_drum", "bass_drum", "bd":
            return "arrow.down.to.line.circle.fill"   // punchy low hit
        case "snare", "snare_drum", "sd":
            return "circle.grid.cross.fill"           // snare cross-wires
        case "toms", "tom", "floor_tom", "rack_tom":
            return "circle.grid.2x2.fill"             // multi-tom pack
        case "hh", "hihat", "hi_hat", "hats":
            return "triangle.fill"                    // closed/open hat
        case "cymbals", "cymbal", "crash", "ride", "overhead", "oh":
            return "sun.max.fill"                     // bright metallic splash
        case "percussion", "perc", "tabla", "pakhawaj", "shaker":
            return "hands.clap.fill"
        case "drums", "drum":
            return "music.quarternote.3"
        case "no_drums", "nodrums":
            return "speaker.slash.fill"

        // —— Bass / low end ——
        case "bass", "bass_guitar", "electric_bass", "upright_bass":
            return "waveform.path.badge.minus"

        // —— Keys ——
        case "piano", "keys", "keys_piano", "keys_other", "electric_piano", "epiano", "organ":
            return "pianokeys"

        // —— Guitars ——
        case "guitar", "guitars", "electric_guitar", "acoustic_guitar", "rhythm_guitar", "lead_guitar":
            return "guitars"

        // —— Strings / world ——
        case "sitar":
            return "music.note"
        case "violin", "viola", "cello", "strings", "string":
            return "headphones"
        case "flute", "woodwind", "winds":
            return "wind"
        case "sax", "saxophone", "brass", "horn":
            return "music.mic"
        case "harmonica", "harmon":
            return "music.mic"

        // —— Beds / residual ——
        case "instrumental", "instruments", "inst", "karaoke":
            return "music.note.list"
        case "other", "rest", "remainder", "noise":
            return "ellipsis.circle.fill"
        case "accompaniment", "backing_track", "bed":
            return "rectangle.stack.fill"

        default:
            if kind.contains("kick") { return "arrow.down.to.line.circle.fill" }
            if kind.contains("snare") { return "circle.grid.cross.fill" }
            if kind.contains("tom") { return "circle.grid.2x2.fill" }
            if kind.contains("hat") || kind == "hh" { return "triangle.fill" }
            if kind.contains("cymbal") || kind.contains("crash") || kind.contains("ride") {
                return "sun.max.fill"
            }
            if kind.contains("drum") { return "music.quarternote.3" }
            if kind.contains("vocal") || kind.contains("lead") { return "mic.fill" }
            if kind.contains("bass") { return "waveform.path.badge.minus" }
            if kind.contains("guitar") { return "guitars" }
            if kind.contains("piano") || kind.contains("key") { return "pianokeys" }
            if kind.contains("flute") || kind.contains("wind") { return "wind" }
            if kind.contains("sax") || kind.contains("brass") { return "music.mic" }
            if kind.contains("violin") || kind.contains("string") { return "headphones" }
            return "waveform"
        }
    }

    static func color(for stem: String) -> Color {
        let kind = baseKind(from: stem)

        if isBackVocal(kind) { return .yellow }
        if isLeadVocal(kind) { return .orange }

        switch kind {
        case "vocals", "vocal", "speech", "speak":
            return .orange

        case "kick", "kick_drum", "bass_drum", "bd":
            return Color(red: 0.95, green: 0.22, blue: 0.18)       // deep red
        case "snare", "snare_drum", "sd":
            return Color(red: 1.0, green: 0.48, blue: 0.12)        // orange-red
        case "toms", "tom", "floor_tom", "rack_tom":
            return Color(red: 0.82, green: 0.18, blue: 0.48)       // magenta
        case "hh", "hihat", "hi_hat", "hats":
            return Color(red: 0.95, green: 0.78, blue: 0.15)       // gold
        case "cymbals", "cymbal", "crash", "ride", "overhead", "oh":
            return Color(red: 0.45, green: 0.72, blue: 1.0)        // steel blue
        case "percussion", "perc", "tabla", "pakhawaj", "shaker":
            return Color(red: 0.9, green: 0.4, blue: 0.3)
        case "drums", "drum":
            return .red
        case "no_drums", "nodrums":
            return .indigo

        case "bass", "bass_guitar", "electric_bass", "upright_bass":
            return .purple

        case "piano", "keys", "keys_piano", "keys_other", "electric_piano", "epiano", "organ":
            return .green

        case "guitar", "guitars", "electric_guitar", "acoustic_guitar", "rhythm_guitar", "lead_guitar":
            return .cyan

        case "sitar":
            return Color(red: 0.95, green: 0.75, blue: 0.2)
        case "violin", "viola", "cello", "strings", "string":
            return Color(red: 0.7, green: 0.5, blue: 0.95)
        case "flute", "woodwind", "winds", "sax", "saxophone", "brass", "horn", "harmonica", "harmon":
            return Color(red: 0.3, green: 0.85, blue: 0.7)

        case "instrumental", "instruments", "inst", "karaoke":
            return .mint
        case "other", "rest", "remainder", "noise":
            return .blue
        case "accompaniment", "backing_track", "bed":
            return Color(red: 0.4, green: 0.55, blue: 0.9)

        default:
            if kind.contains("kick") { return Color(red: 0.95, green: 0.22, blue: 0.18) }
            if kind.contains("snare") { return Color(red: 1.0, green: 0.48, blue: 0.12) }
            if kind.contains("tom") { return Color(red: 0.82, green: 0.18, blue: 0.48) }
            if kind.contains("hat") || kind == "hh" { return Color(red: 0.95, green: 0.78, blue: 0.15) }
            if kind.contains("cymbal") || kind.contains("crash") {
                return Color(red: 0.45, green: 0.72, blue: 1.0)
            }
            if kind.contains("drum") { return .red }
            if kind.contains("vocal") { return .orange }
            if kind.contains("bass") { return .purple }
            if kind.contains("guitar") { return .cyan }
            if kind.contains("piano") || kind.contains("key") { return .green }
            return .blue
        }
    }

    static func accessibilityLabel(for stem: String) -> String {
        let kind = baseKind(from: stem)
        if isLeadVocal(kind) { return "Lead vocal" }
        if isBackVocal(kind) { return "Backing vocal" }
        switch kind {
        case "kick", "kick_drum", "bd": return "Kick"
        case "snare", "snare_drum", "sd": return "Snare"
        case "toms", "tom": return "Toms"
        case "hh", "hihat", "hi_hat", "hats": return "Hi-hat"
        case "cymbals", "cymbal", "crash", "ride": return "Cymbals"
        case "no_drums", "nodrums": return "No drums"
        default:
            return stem.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }

    // MARK: - Lead / Back

    private static func isLeadVocal(_ kind: String) -> Bool {
        switch kind {
        case "lead", "lead_vocal", "lead_vocals", "leadvocal", "leadvocals":
            return true
        default:
            return kind.contains("lead") && (kind.contains("vocal") || kind == "lead")
        }
    }

    private static func isBackVocal(_ kind: String) -> Bool {
        switch kind {
        case "back", "back_vocal", "back_vocals", "backing", "backing_vocal",
             "backing_vocals", "backvocal", "backvocals", "bgv", "bg_vocals":
            return true
        default:
            if kind.contains("back") && kind.contains("vocal") { return true }
            if kind.contains("backing") { return true }
            return kind == "back"
        }
    }
}

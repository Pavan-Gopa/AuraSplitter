import AppKit
import AVFoundation
import Foundation

enum FileHelpers {
    static func reveal(path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    static func formattedBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func formattedDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m \(remainingSeconds)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        return "\(remainingSeconds)s"
    }

    static func formattedDurationWithRawSeconds(_ seconds: Double) -> String {
        "\(formattedDuration(seconds)) (\(String(format: "%.1f", seconds))s)"
    }
}

final class StemPreviewPlayer: ObservableObject {
    @Published var playingPath: String?

    private var player: AVAudioPlayer?

    func toggle(path: String) {
        if playingPath == path {
            stop()
            return
        }

        stop()
        let url = URL(fileURLWithPath: path)
        guard let nextPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        player = nextPlayer
        playingPath = path
        nextPlayer.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + nextPlayer.duration) { [weak self] in
            if self?.playingPath == path {
                self?.playingPath = nil
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingPath = nil
    }
}

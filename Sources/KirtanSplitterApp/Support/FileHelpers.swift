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

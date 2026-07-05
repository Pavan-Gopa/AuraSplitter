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

    static func formattedTimestamp(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
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

final class AudioPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingPath: String?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(path: String) {
        if playingPath != path {
            load(path: path)
        }

        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(path: String, time: Double) {
        if playingPath != path {
            load(path: path)
        }
        guard let player else { return }
        let clamped = min(max(0, time), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    func stop() {
        player?.stop()
        player = nil
        playingPath = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        stopTimer()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentTime = player.duration
        stopTimer()
    }

    private func load(path: String) {
        stop()
        let url = URL(fileURLWithPath: path)
        guard let nextPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        nextPlayer.delegate = self
        player = nextPlayer
        playingPath = path
        duration = nextPlayer.duration
        currentTime = 0
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
            self.duration = player.duration
            self.isPlaying = player.isPlaying
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

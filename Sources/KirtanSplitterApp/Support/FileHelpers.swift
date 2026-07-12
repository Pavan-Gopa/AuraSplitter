import AppKit
import AVFoundation
import Foundation

enum FileHelpers {
    static func reveal(path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    static func open(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    static func readTrailingText(path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer {
            try? handle.close()
        }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let byteCount = UInt64(max(0, maxBytes))
        let offset = fileSize > byteCount ? fileSize - byteCount : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    static func exportText(_ text: String, suggestedFilename: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
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

final class AudioPreviewPlayer: NSObject, ObservableObject {
    @Published var playingPath: String?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var volume: Double = 1

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let gainNode = AVAudioUnitEQ(numberOfBands: 0)
    private var audioFile: AVAudioFile?
    private var timer: Timer?
    private var playbackStartDate: Date?
    private var playbackStartTime: Double = 0
    private var completionToken = UUID()

    override init() {
        super.init()
        engine.attach(playerNode)
        engine.attach(gainNode)
        engine.connect(playerNode, to: gainNode, format: nil)
        engine.connect(gainNode, to: engine.mainMixerNode, format: nil)
        applyVolume()
    }

    func toggle(path: String) {
        if playingPath != path {
            load(path: path)
        }

        guard audioFile != nil else { return }
        if isPlaying {
            pause()
        } else {
            playFromCurrentTime()
        }
    }

    func seek(path: String, time: Double) {
        let wasPlaying = isPlaying
        if playingPath != path {
            load(path: path)
        }
        guard audioFile != nil else { return }
        let clamped = min(max(0, time), duration)
        currentTime = clamped
        playbackStartTime = clamped
        if wasPlaying {
            playFromCurrentTime()
        }
    }

    func setVolume(_ nextVolume: Double) {
        volume = AudioPreviewVolume.clamp(nextVolume)
        applyVolume()
    }

    func stop() {
        completionToken = UUID()
        playerNode.stop()
        audioFile = nil
        playingPath = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        playbackStartDate = nil
        playbackStartTime = 0
        stopTimer()
    }

    private func pause() {
        currentTime = currentPlaybackTime()
        playbackStartTime = currentTime
        playbackStartDate = nil
        playerNode.pause()
        isPlaying = false
        stopTimer()
    }

    private func load(path: String) {
        stop()
        let url = URL(fileURLWithPath: path)
        guard let nextFile = try? AVAudioFile(forReading: url) else { return }
        audioFile = nextFile
        playingPath = path
        duration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
        currentTime = 0
        playbackStartTime = 0
    }

    private func playFromCurrentTime() {
        guard let audioFile else { return }
        completionToken = UUID()
        let token = completionToken
        let sampleRate = audioFile.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(min(max(0, playbackStartTime), duration) * sampleRate)
        let remainingFrames = max(0, audioFile.length - startFrame)
        guard remainingFrames > 0 else {
            currentTime = duration
            isPlaying = false
            return
        }

        playerNode.stop()
        playerNode.scheduleSegment(
            audioFile,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remainingFrames),
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.completionToken == token, self.isPlaying else { return }
                self.currentTime = self.duration
                self.playbackStartTime = self.duration
                self.playbackStartDate = nil
                self.isPlaying = false
                self.stopTimer()
            }
        }

        do {
            if !engine.isRunning {
                try engine.start()
            }
            playbackStartDate = Date()
            playerNode.play()
            isPlaying = true
            startTimer()
        } catch {
            isPlaying = false
            stopTimer()
        }
    }

    private func currentPlaybackTime() -> Double {
        guard isPlaying, let playbackStartDate else { return currentTime }
        return min(duration, playbackStartTime + Date().timeIntervalSince(playbackStartDate))
    }

    private func applyVolume() {
        if volume <= 0.001 {
            gainNode.globalGain = -96
        } else {
            gainNode.globalGain = Float(20 * log10(volume))
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.currentTime = self.currentPlaybackTime()
            if self.currentTime >= self.duration {
                self.isPlaying = false
                self.stopTimer()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

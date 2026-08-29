import Foundation

/// Builds a temp WAV with exclusion zones removed (kept segments concatenated).
/// Preserves source bit depth / sample rate / channel count (never force 16-bit).
enum AutomationAudioCutter {
    struct AudioFormat: Equatable {
        var channels: Int?
        var sampleRate: Int?
        var bitDepth: Int?
        var sampleFmt: String?
        var codecName: String?

        /// ffmpeg -c:a value that preserves source quality for WAV.
        var pcmCodec: String {
            if let codec = codecName?.lowercased() {
                switch codec {
                case "pcm_s24le", "pcm_s24be": return "pcm_s24le"
                case "pcm_s32le", "pcm_s32be": return "pcm_s32le"
                case "pcm_f32le", "pcm_f32be": return "pcm_f32le"
                case "pcm_s16le", "pcm_s16be": return "pcm_s16le"
                default: break
                }
            }
            switch bitDepth {
            case 24: return "pcm_s24le"
            case 32: return sampleFmt?.contains("flt") == true ? "pcm_f32le" : "pcm_s32le"
            case 16: return "pcm_s16le"
            default: return "pcm_s24le" // prefer 24 over silent 16 downgrade
            }
        }
    }

    enum CutError: LocalizedError {
        case ffmpegMissing
        case ffmpegFailed(String)
        case noKeptAudio

        var errorDescription: String? {
            switch self {
            case .ffmpegMissing:
                return "ffmpeg not found (needed to apply cut regions)."
            case .ffmpegFailed(let msg):
                return "Cut failed: \(msg)"
            case .noKeptAudio:
                return "Cut regions remove the entire track — nothing left to separate."
            }
        }
    }

    /// Returns `source` unchanged when there are no valid exclusions; otherwise a new temp file
    /// encoded with the same PCM bit depth as the source (not forced to 16-bit).
    static func prepareInput(
        source: URL,
        exclusionZones: [AutomationTimeRange],
        durationSeconds: Double?
    ) throws -> (url: URL, isTemporary: Bool) {
        let merged = AutomationTimeRange.merge(exclusionZones)
        guard !merged.isEmpty else {
            return (source, false)
        }

        let duration = durationSeconds ?? probeDuration(source) ?? 0
        guard duration > 0.05 else {
            return (source, false)
        }

        let kept = AutomationTimeRange.keptSegments(duration: duration, excluding: merged)
        guard !kept.isEmpty else {
            throw CutError.noKeptAudio
        }
        if kept.count == 1,
           kept[0].start <= 0.02,
           kept[0].end >= duration - 0.02 {
            return (source, false)
        }

        let ffmpeg = resolveFFmpeg()
        guard !ffmpeg.isEmpty else { throw CutError.ffmpegMissing }

        let format = probeFormat(source) ?? AudioFormat(bitDepth: 24)
        let codec = format.pcmCodec

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura_auto_cut_\(UUID().uuidString).wav")

        if kept.count == 1 {
            let k = kept[0]
            var args = [
                "-y", "-hide_banner", "-loglevel", "error",
                "-ss", String(format: "%.3f", k.start),
                "-to", String(format: "%.3f", k.end),
                "-i", source.path,
                "-map", "0:a:0",
                "-vn",
                "-c:a", codec,
            ]
            if let ch = format.channels { args += ["-ac", "\(ch)"] }
            if let ar = format.sampleRate { args += ["-ar", "\(ar)"] }
            args.append(out.path)
            try runFFmpeg(ffmpeg, arguments: args)
        } else {
            var filters: [String] = []
            var labels: [String] = []
            for (i, k) in kept.enumerated() {
                let label = "a\(i)"
                filters.append(
                    "[0:a]atrim=start=\(String(format: "%.3f", k.start)):end=\(String(format: "%.3f", k.end)),asetpts=PTS-STARTPTS[\(label)]"
                )
                labels.append("[\(label)]")
            }
            let concat = labels.joined() + "concat=n=\(kept.count):v=0:a=1[out]"
            filters.append(concat)
            var args = [
                "-y", "-hide_banner", "-loglevel", "error",
                "-i", source.path,
                "-filter_complex", filters.joined(separator: ";"),
                "-map", "[out]",
                "-c:a", codec,
            ]
            if let ch = format.channels { args += ["-ac", "\(ch)"] }
            if let ar = format.sampleRate { args += ["-ar", "\(ar)"] }
            args.append(out.path)
            try runFFmpeg(ffmpeg, arguments: args)
        }

        guard FileManager.default.fileExists(atPath: out.path) else {
            throw CutError.ffmpegFailed("output missing")
        }
        return (out, true)
    }

    /// Re-encode `file` to match `reference` bit depth / rate / channels (WAV).
    /// Used after automation copies if we need to guarantee source fidelity.
    static func conformWAV(_ file: URL, toMatch reference: URL) throws {
        let ffmpeg = resolveFFmpeg()
        guard !ffmpeg.isEmpty else { throw CutError.ffmpegMissing }
        guard let format = probeFormat(reference) else { return }
        let current = probeFormat(file)
        if current?.bitDepth == format.bitDepth,
           current?.channels == format.channels,
           current?.sampleRate == format.sampleRate {
            return
        }
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".conform.tmp.wav")
        var args = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", file.path,
            "-map", "0:a:0",
            "-vn",
            "-c:a", format.pcmCodec,
        ]
        if let ch = format.channels { args += ["-ac", "\(ch)"] }
        if let ar = format.sampleRate { args += ["-ar", "\(ar)"] }
        args.append(temp.path)
        try runFFmpeg(ffmpeg, arguments: args)
        let fm = FileManager.default
        try? fm.removeItem(at: file)
        try fm.moveItem(at: temp, to: file)
    }

    static func resolveFFmpeg() -> String {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "bin") {
            candidates.append(bundled.path)
        }
        candidates += [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["ffmpeg"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : ""
    }

    static func probeFormat(_ url: URL) -> AudioFormat? {
        let ffprobe = resolveFFprobe()
        guard !ffprobe.isEmpty else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffprobe)
        task.arguments = [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=channels,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,codec_name",
            "-of", "json",
            url.path,
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let streams = json["streams"] as? [[String: Any]],
            let stream = streams.first
        else { return nil }

        let channels = (stream["channels"] as? Int)
            ?? (stream["channels"] as? String).flatMap(Int.init)
        let sampleRate = (stream["sample_rate"] as? String).flatMap(Int.init)
            ?? (stream["sample_rate"] as? Int)
        var bitDepth = (stream["bits_per_raw_sample"] as? String).flatMap(Int.init)
            ?? (stream["bits_per_raw_sample"] as? Int)
        if bitDepth == nil || bitDepth == 0 {
            bitDepth = (stream["bits_per_sample"] as? String).flatMap(Int.init)
                ?? (stream["bits_per_sample"] as? Int)
        }
        let sampleFmt = stream["sample_fmt"] as? String
        if bitDepth == nil || bitDepth == 0, let fmt = sampleFmt {
            // s16 / s32 / s32 / fltp
            if fmt.contains("16") { bitDepth = 16 }
            else if fmt.contains("24") { bitDepth = 24 }
            else if fmt.contains("32") { bitDepth = 32 }
        }
        let codec = stream["codec_name"] as? String
        return AudioFormat(
            channels: channels,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            sampleFmt: sampleFmt,
            codecName: codec
        )
    }

    private static func resolveFFprobe() -> String {
        let ffmpeg = resolveFFmpeg()
        if !ffmpeg.isEmpty {
            let probe = ffmpeg.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
            if FileManager.default.isExecutableFile(atPath: probe) { return probe }
        }
        for path in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return ""
    }

    private static func probeDuration(_ url: URL) -> Double? {
        let ffprobe = resolveFFprobe()
        guard !ffprobe.isEmpty else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffprobe)
        task.arguments = [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", url.path,
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Double(text)
        } catch {
            return nil
        }
    }

    private static func runFFmpeg(_ binary: String, arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = arguments
        let err = Pipe()
        task.standardError = err
        task.standardOutput = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            throw CutError.ffmpegFailed(error.localizedDescription)
        }
        guard task.terminationStatus == 0 else {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit \(task.terminationStatus)"
            throw CutError.ffmpegFailed(msg.isEmpty ? "exit \(task.terminationStatus)" : msg)
        }
    }
}

import Foundation

struct BatchSourceItem: Identifiable, Equatable {
    var id: String { url.path }

    let url: URL
    var isSelectedForProcessing: Bool
    var presetID: String
    var analysis: AudioAnalysis?
    var analysisError: String?
    var isAnalyzing = false

    var fileName: String {
        url.lastPathComponent
    }
}

struct BatchResultGroup: Identifiable {
    var id: String { sourceURL.path }

    let sourceURL: URL
    var summary: SeparationSummary?
    var files: [StemFile]

    var sourceName: String {
        sourceURL.lastPathComponent
    }
}

enum AudioPreviewSelection: Equatable {
    case none
    case source(String)
    case result(String)
}

enum BatchWorkspace {
    static let supportedAudioExtensions: Set<String> = ["wav", "wave", "flac", "aif", "aiff", "m4a", "mp3"]

    static func audioFiles(in folder: URL, fileManager: FileManager = .default) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true && isSupportedAudioFile(url)
            }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    static func makeSources(from urls: [URL], defaultPresetID: String) -> [BatchSourceItem] {
        urls
            .filter(isSupportedAudioFile)
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .map { url in
                BatchSourceItem(
                    url: url,
                    isSelectedForProcessing: true,
                    presetID: defaultPresetID
                )
            }
    }

    static func deleteStem(
        at path: String,
        from groups: inout [BatchResultGroup],
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
        // Remove experiment sidecar if present.
        let audioURL = URL(fileURLWithPath: path)
        let sidecarBase = audioURL.deletingLastPathComponent()
            .appendingPathComponent(audioURL.deletingPathExtension().lastPathComponent)
        let sidecarAura = sidecarBase.appendingPathExtension("aura-run.json")
        let sidecarKirtan = sidecarBase.appendingPathExtension("kirtan-run.json")
        for file in [sidecarAura, sidecarKirtan] {
            if fileManager.fileExists(atPath: file.path) {
                try? fileManager.removeItem(at: file)
            }
        }

        groups = groups.compactMap { group in
            var nextGroup = group
            nextGroup.files.removeAll { $0.path == path }
            return nextGroup.files.isEmpty ? nil : nextGroup
        }
    }

    static func effectivePresetID(
        for source: BatchSourceItem,
        sourceCount: Int,
        globalPresetID: String
    ) -> String {
        sourceCount > 1 ? source.presetID : globalPresetID
    }

    static func isSupportedAudioFile(_ url: URL) -> Bool {
        supportedAudioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Default on-disk stems folder next to the source: `SongName_stems/`.
    static func defaultStemsDirectory(for sourceURL: URL) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + "_stems")
    }

    /// Load previously exported stems so Results shows experiments without re-running.
    static func discoverStemFiles(
        in folder: URL,
        relatedTo sourceURL: URL,
        fileManager: FileManager = .default
    ) -> [StemFile] {
        guard fileManager.fileExists(atPath: folder.path) else { return [] }

        let sourceStem = sourceURL.deletingPathExtension().lastPathComponent
        let urls = audioFiles(in: folder, fileManager: fileManager)
            .filter { url in
                // Prefer files that belong to this source; still accept _(role) stems in the folder.
                let name = url.deletingPathExtension().lastPathComponent
                if name.hasPrefix(sourceStem) { return true }
                return stemRoleLabel(fromFileStem: name) != nil
            }

        return urls.compactMap { url -> StemFile? in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let size = values?.fileSize ?? 0
            let role = stemRoleLabel(fromFileStem: url.deletingPathExtension().lastPathComponent)
                ?? "stem"
            let kind = role.lowercased().replacingOccurrences(of: " ", with: "_")
            var file = StemFile(stem: kind, path: url.path, sizeBytes: size, runInfo: nil)
            file.loadRunInfoFromSidecar()
            return file
        }
        .sorted { lhs, rhs in
            let leftBase = lhs.stem.replacingOccurrences(of: #"_\d+$"#, with: "", options: .regularExpression)
            let rightBase = rhs.stem.replacingOccurrences(of: #"_\d+$"#, with: "", options: .regularExpression)
            if leftBase != rightBase {
                return leftBase < rightBase
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Extract `vocals` / `vocals 2` from `Song_(vocals 2)_Model.wav`.
    static func stemRoleLabel(fromFileStem fileStem: String) -> String? {
        guard let open = fileStem.range(of: "_("),
              let close = fileStem.range(of: ")", range: open.upperBound..<fileStem.endIndex)
        else { return nil }
        let role = String(fileStem[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        return role.isEmpty ? nil : role
    }
}

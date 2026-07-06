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
}

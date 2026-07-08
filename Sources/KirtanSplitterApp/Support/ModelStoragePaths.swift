import Foundation

enum ModelStoragePaths {
    static let localModelsFolderName = "AI_LOCAL_MODELS"
    static let soundFolderName = "Sound"
    static let appFolderName = "KirtanSplitter"

    static func defaultModelDirectory(homeDirectory: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(localModelsFolderName)
            .appendingPathComponent(soundFolderName)
            .appendingPathComponent(appFolderName)
            .path
    }

    static func legacyApplicationSupportModelDirectory(homeDirectory: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support/KirtanSplitter/models")
            .path
    }

    @discardableResult
    static func prepareDefaultModelDirectoryAndMigrateLegacyCache(
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let targetPath = defaultModelDirectory(homeDirectory: homeDirectory)
        let legacyPath = legacyApplicationSupportModelDirectory(homeDirectory: homeDirectory)
        try? fileManager.createDirectory(
            at: URL(fileURLWithPath: targetPath),
            withIntermediateDirectories: true
        )
        try? mergeDirectoryContents(
            from: URL(fileURLWithPath: legacyPath),
            to: URL(fileURLWithPath: targetPath),
            fileManager: fileManager
        )
        return targetPath
    }

    static func prepareModelDirectory(_ path: String, fileManager: FileManager = .default) {
        try? fileManager.createDirectory(
            at: URL(fileURLWithPath: path),
            withIntermediateDirectories: true
        )
    }

    private static func mergeDirectoryContents(
        from source: URL,
        to target: URL,
        fileManager: FileManager
    ) throws {
        var sourceIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory),
              sourceIsDirectory.boolValue
        else { return }

        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)

        let items = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for item in items {
            let destination = target.appendingPathComponent(item.lastPathComponent)
            var destinationIsDirectory = ObjCBool(false)
            let destinationExists = fileManager.fileExists(
                atPath: destination.path,
                isDirectory: &destinationIsDirectory
            )
            let itemIsDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if destinationExists {
                if itemIsDirectory && destinationIsDirectory.boolValue {
                    try mergeDirectoryContents(from: item, to: destination, fileManager: fileManager)
                }
                continue
            }

            try fileManager.copyItem(at: item, to: destination)
        }
    }
}

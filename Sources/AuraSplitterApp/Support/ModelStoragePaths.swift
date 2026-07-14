import Foundation

/// User-visible brand folder name (models, App Support, caches).
/// Binary/module may still be named KirtanSplitter until a full package rebrand.
enum AppBrand {
    static let displayName = "AuraSplitter"
    static let folderName = "AuraSplitter"
    /// Pre-rebrand paths — migrated on first launch.
    static let legacyFolderName = "KirtanSplitter"
}

enum ModelStoragePaths {
    static let localModelsFolderName = "AI_LOCAL_MODELS"
    static let soundFolderName = "Sound"
    static let appFolderName = AppBrand.folderName
    static let legacyAppFolderName = AppBrand.legacyFolderName

    static func defaultModelDirectory(homeDirectory: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(localModelsFolderName)
            .appendingPathComponent(soundFolderName)
            .appendingPathComponent(appFolderName)
            .path
    }

    static func legacySoundModelDirectory(homeDirectory: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(localModelsFolderName)
            .appendingPathComponent(soundFolderName)
            .appendingPathComponent(legacyAppFolderName)
            .path
    }

    static func legacyApplicationSupportModelDirectory(homeDirectory: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support/\(legacyAppFolderName)/models")
            .path
    }

    static func applicationSupportDirectory(homeDirectory: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support/\(appFolderName)")
            .path
    }

    static func legacyApplicationSupportDirectory(homeDirectory: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support/\(legacyAppFolderName)")
            .path
    }

    static func defaultLogFile(homeDirectory: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: applicationSupportDirectory(homeDirectory: homeDirectory))
            .appendingPathComponent("logs/backend.log")
            .path
    }

    static func defaultRuntimeDirectory(homeDirectory: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: applicationSupportDirectory(homeDirectory: homeDirectory))
            .appendingPathComponent("runtime")
            .path
    }

    @discardableResult
    static func prepareDefaultModelDirectoryAndMigrateLegacyCache(
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let targetPath = defaultModelDirectory(homeDirectory: homeDirectory)
        try? fileManager.createDirectory(
            at: URL(fileURLWithPath: targetPath),
            withIntermediateDirectories: true
        )

        // 1) Old brand under AI_LOCAL_MODELS/Sound/KirtanSplitter
        try? mergeDirectoryContents(
            from: URL(fileURLWithPath: legacySoundModelDirectory(homeDirectory: homeDirectory)),
            to: URL(fileURLWithPath: targetPath),
            fileManager: fileManager
        )
        // 2) Very old cache under Application Support/.../models
        try? mergeDirectoryContents(
            from: URL(fileURLWithPath: legacyApplicationSupportModelDirectory(homeDirectory: homeDirectory)),
            to: URL(fileURLWithPath: targetPath),
            fileManager: fileManager
        )
        return targetPath
    }

    /// Copy App Support tree KirtanSplitter → AuraSplitter when needed (logs, runtime staging).
    static func prepareApplicationSupportAndMigrateLegacy(
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) {
        let target = URL(fileURLWithPath: applicationSupportDirectory(homeDirectory: homeDirectory))
        let legacy = URL(fileURLWithPath: legacyApplicationSupportDirectory(homeDirectory: homeDirectory))
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try? mergeDirectoryContents(from: legacy, to: target, fileManager: fileManager)
        try? fileManager.createDirectory(
            at: target.appendingPathComponent("logs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            at: target.appendingPathComponent("runtime", isDirectory: true),
            withIntermediateDirectories: true
        )
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
